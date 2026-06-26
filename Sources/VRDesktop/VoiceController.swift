import AVFoundation
import Speech

/// Drives on-device speech recognition for voice control. Two modes:
/// - **push-to-talk**: one listen window, auto-stopped after a short silence (or a hard cap).
/// - **wake word**: continuous; the words after the wake word become the command, fired on a pause.
///
/// Recognition is on-device only (no audio leaves the Mac). Uses an `AVAudioEngine` input tap, which
/// is independent of the `AVCaptureSession` the recorder uses, so the two don't share a graph.
///
/// All logic runs on the main thread: the recognition callback is bounced to main, and the public
/// methods are called from the (main-actor) coordinator, so internal state is single-threaded.
final class VoiceController {
    enum Mode { case idle, pushToTalk, wakeWord }
    private(set) var mode: Mode = .idle

    var onPartial: ((String) -> Void)?
    var onCommand: ((String) -> Void)?
    var onListeningChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    /// Wake word used in wake-word mode (set by the coordinator).
    var wakeWord = "computer"
    /// Known command phrases (+ workspace names) used to bias recognition toward what we expect.
    /// Set by the coordinator before each listen. Big accuracy win for a fixed vocabulary.
    var contextualPhrases: [String] = []

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var capTimer: Timer?
    private var finalTimer: Timer?
    private var endingAudio = false
    private var lastPartial = ""
    private var wakeArmed = false
    private var pendingWakeCommand = ""

    var isListening: Bool { mode != .idle }
    static var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// Push-to-talk timing (user-tunable). `pttStartTimeout`: how long to wait for speech to *begin*
    /// after the hotkey. `pttSilenceTimeout`: how much silence after the last word ends the command.
    var pttStartTimeout: TimeInterval = 4.0
    var pttSilenceTimeout: TimeInterval = 2.0
    private let pttHardCap: TimeInterval = 20.0
    private let wakeSilenceTimeout: TimeInterval = 1.5

    /// Allow Apple's server (cloud) recognition. When false, recognition is on-device only.
    var allowRemote = false

    // MARK: Authorization

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    // MARK: Control

    /// Tap-to-talk: listen for a single command, auto-stopping on silence.
    func startPushToTalk() {
        guard mode == .idle else { return }
        lastPartial = ""
        guard startEngine() else { return }
        mode = .pushToTalk
        onListeningChanged?(true)
        armCap(pttHardCap)
        armSilence(pttStartTimeout)   // generous wait for speech to begin
    }

    /// Continuous wake-word listening.
    func startWakeWord() {
        guard mode != .wakeWord else { return }
        stop()
        wakeArmed = false; pendingWakeCommand = ""; lastPartial = ""
        guard startEngine() else { return }
        mode = .wakeWord
        onListeningChanged?(true)
    }

    /// Stop everything (idempotent).
    func stop() {
        silenceTimer?.invalidate(); silenceTimer = nil
        capTimer?.invalidate(); capTimer = nil
        finalTimer?.invalidate(); finalTimer = nil
        endingAudio = false
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        let wasListening = mode != .idle
        mode = .idle
        wakeArmed = false; pendingWakeCommand = ""
        if wasListening { onListeningChanged?(false) }
    }

    // MARK: Engine

    @discardableResult
    private func startEngine() -> Bool {
        guard Self.isAuthorized else { onError?("Speech permission not granted"); return false }
        guard let recognizer, recognizer.isAvailable else {
            onError?("Speech recognizer unavailable"); return false
        }
        if !allowRemote, !recognizer.supportsOnDeviceRecognition {
            onError?("On-device voice isn't available for this language — enable Higher accuracy to use the cloud")
            return false
        }
        task?.cancel(); task = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = !allowRemote
        // Bias toward our known commands + hint the engine these are short commands, not dictation.
        req.contextualStrings = Array(contextualPhrases.prefix(100))
        req.taskHint = .search
        request = req
        endingAudio = false

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("No microphone input"); request = nil; return false
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("Couldn't start audio: \(error.localizedDescription)")
            input.removeTap(onBus: 0); request = nil; return false
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handleResult(result, error: error) }
        }
        return true
    }

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            lastPartial = text
            if mode == .pushToTalk {
                onPartial?(text)
                if result.isFinal {
                    finishPushToTalk(text)            // the engine's best, fully-processed guess
                } else if !endingAudio {
                    armSilence(pttSilenceTimeout)     // reset end-of-speech countdown on new words
                }
            } else if mode == .wakeWord {
                handleWakeTranscript(text, isFinal: result.isFinal)
            }
        }
        if error != nil {
            switch mode {
            case .pushToTalk: finishPushToTalk(lastPartial)
            case .wakeWord:   recycleWakeWord()
            case .idle:       break
            }
        }
    }

    // MARK: Push-to-talk timers

    private func armSilence(_ seconds: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.mode == .pushToTalk { self.endPushToTalkAudio() }
            else if self.mode == .wakeWord { self.fireWakeCommand() }
        }
    }

    private func armCap(_ seconds: TimeInterval) {
        capTimer?.invalidate()
        capTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.mode == .pushToTalk else { return }
            self.endPushToTalkAudio()
        }
    }

    /// Stop feeding audio and ask the recognizer to finalize, so we act on its best full-utterance
    /// transcription rather than a mid-stream partial. Falls back to the last partial if no final.
    private func endPushToTalkAudio() {
        guard mode == .pushToTalk, !endingAudio else { return }
        endingAudio = true
        silenceTimer?.invalidate(); silenceTimer = nil
        request?.endAudio()
        finalTimer?.invalidate()
        finalTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, self.mode == .pushToTalk else { return }
            self.finishPushToTalk(self.lastPartial)
        }
    }

    private func finishPushToTalk(_ text: String) {
        guard mode == .pushToTalk else { return }
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if !phrase.isEmpty { onCommand?(phrase) }
    }

    // MARK: Wake word

    private func handleWakeTranscript(_ text: String, isFinal: Bool) {
        onPartial?(text)
        let lower = VoiceCommandStore.normalize(text)
        let wake = VoiceCommandStore.normalize(wakeWord)
        if !wake.isEmpty, let r = lower.range(of: wake, options: .backwards) {
            wakeArmed = true
            pendingWakeCommand = String(lower[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if isFinal {
                fireWakeCommand()
            } else if !pendingWakeCommand.isEmpty {
                armSilence(wakeSilenceTimeout)   // fire after a pause
            }
        } else if isFinal {
            recycleWakeWord()     // utterance ended without the wake word — start fresh
        }
    }

    private func fireWakeCommand() {
        guard mode == .wakeWord, wakeArmed else { return }
        let cmd = pendingWakeCommand
        wakeArmed = false; pendingWakeCommand = ""
        if !cmd.isEmpty { onCommand?(cmd) }
        recycleWakeWord()
    }

    /// Tear down and restart the recognition task so the transcript buffer resets (SFSpeech degrades
    /// over long continuous sessions). Keeps `mode == .wakeWord`.
    private func recycleWakeWord() {
        guard mode == .wakeWord else { return }
        silenceTimer?.invalidate(); silenceTimer = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        wakeArmed = false; pendingWakeCommand = ""; lastPartial = ""
        if !startEngine() {
            mode = .idle
            onListeningChanged?(false)
        }
    }
}

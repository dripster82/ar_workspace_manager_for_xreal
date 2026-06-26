import AudioToolbox
import AVFoundation
import CoreAudio
import QuartzCore
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
    enum Mode { case idle, pushToTalk, wakeWord, metering }
    private(set) var mode: Mode = .idle

    var onPartial: ((String) -> Void)?
    var onCommand: ((String) -> Void)?
    var onListeningChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    /// Live input level (0…1) from the mic tap, for the level meter. Throttled to ~25 Hz on the main thread.
    var onLevel: ((Float) -> Void)?
    private var lastLevelAt: CFTimeInterval = 0

    /// Wake word used in wake-word mode (set by the coordinator).
    var wakeWord = "computer"
    /// Known command phrases (+ workspace names) used to bias recognition toward what we expect.
    /// Set by the coordinator before each listen. Big accuracy win for a fixed vocabulary.
    var contextualPhrases: [String] = []
    /// Preferred input device (an AVCaptureDevice/CoreAudio UID) to listen on, or nil for the system
    /// default. Mirrors the recording mic picker so voice honours the same choice.
    var inputDeviceUID: String?

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
    private var wakeCapturing = false   // wake word heard → overlay shown for the trailing command
    /// When set, the next push-to-talk result is handed to this (for the per-command "test & learn"
    /// flow) instead of being dispatched as a command.
    private var oneShotCompletion: ((String) -> Void)?

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

    /// Metering only: run the engine + tap purely to report mic level (no recognition). For the
    /// "test mic" level meter. Stop with `stop()`.
    func startMetering() {
        guard mode == .idle else { return }
        guard startAudioEngine() else { return }   // no recognition request → metering only
        mode = .metering
    }

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

    /// One-shot listen for the "test & learn" flow: hands the raw transcript to `completion` instead
    /// of dispatching a command. Reuses the push-to-talk timing.
    func startTest(_ completion: @escaping (String) -> Void) {
        guard mode == .idle else { completion(""); return }
        oneShotCompletion = completion
        startPushToTalk()
        if mode != .pushToTalk { oneShotCompletion = nil; completion("") }   // failed to start
    }

    /// Continuous wake-word listening. The overlay stays HIDDEN until the wake word is heard (it's
    /// shown by `handleWakeTranscript`), so we don't display a persistent "Listening…" popup.
    func startWakeWord() {
        guard mode != .wakeWord else { return }
        stop()
        wakeArmed = false; pendingWakeCommand = ""; lastPartial = ""; wakeCapturing = false
        guard startEngine() else { return }
        mode = .wakeWord
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
        let wasOverlayShown = mode != .idle && (mode != .wakeWord || wakeCapturing)
        let pendingTest = oneShotCompletion; oneShotCompletion = nil
        mode = .idle
        wakeArmed = false; pendingWakeCommand = ""; wakeCapturing = false
        if wasOverlayShown { onListeningChanged?(false) }
        pendingTest?("")   // reset any in-flight test if we were stopped externally
    }

    // MARK: Engine

    /// Engine + tap convenience (audio + a fresh recognition). Used to begin push-to-talk / wake-word.
    @discardableResult
    private func startEngine() -> Bool {
        guard startAudioEngine() else { return false }
        guard startRecognition() else {
            if audioEngine.isRunning { audioEngine.inputNode.removeTap(onBus: 0); audioEngine.stop() }
            return false
        }
        return true
    }

    /// Start the audio engine + a single continuous tap that feeds whatever `request` is current and
    /// reports the mic level. Idempotent — the tap stays up across wake-word utterances (only the
    /// recognition request/task is recycled), which is what makes wake-word reliably keep listening.
    @discardableResult
    private func startAudioEngine() -> Bool {
        if audioEngine.isRunning { return true }
        // System default input (stable). The mic picker sets the default via the HAL; we never poke
        // the engine's input device, which can corrupt the node's format and crash installTap.
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("No microphone input — check the mic and its permission"); return false
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.reportLevel(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() }
        catch {
            onError?("Couldn't start audio: \(error.localizedDescription)")
            input.removeTap(onBus: 0); return false
        }
        return true
    }

    /// Begin (or recycle) a recognition request+task over the already-running tap.
    @discardableResult
    private func startRecognition() -> Bool {
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
        req.contextualStrings = Array(contextualPhrases.prefix(100))   // bias toward known commands
        req.taskHint = .search
        request = req
        endingAudio = false

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handleResult(result, error: error) }
        }
        return true
    }

    /// RMS level (0…1) of a PCM buffer, dB-scaled for a usable meter, throttled to ~25 Hz.
    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastLevelAt > 0.04 else { return }
        lastLevelAt = now
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let data = ch[0]
        var sum: Float = 0
        for i in 0..<n { let s = data[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))            // ~ -140…0 dBFS
        let norm = max(0, min(1, (db + 50) / 50))      // -50…0 dB → 0…1
        DispatchQueue.main.async { [weak self] in self?.onLevel?(norm) }
    }

    /// Set the system default input device (by UID) — the engine follows it safely. Returns success.
    @discardableResult
    static func setDefaultInputDevice(uid: String) -> Bool {
        guard var dev = audioDeviceID(forUID: uid) else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
    }

    /// UID of the current system default input device, for showing the picker's selection.
    static func defaultInputDeviceUID() -> String? {
        guard let dev = defaultInputDevice() else { return nil }
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uidRef: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr else { return nil }
        return uidRef as String?
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return nil }
        return dev
    }

    /// Resolve a CoreAudio device UID (the same string AVCaptureDevice.uniqueID returns for audio
    /// devices) to its AudioDeviceID.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else { return nil }
        for dev in devices {
            var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var uidRef: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            if AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr,
               (uidRef as String?) == uid {
                return dev
            }
        }
        return nil
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
            case .idle, .metering: break
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
        let completion = oneShotCompletion
        oneShotCompletion = nil
        stop()
        if let completion { completion(phrase) }      // test mode: hand back the raw transcript
        else if !phrase.isEmpty { onCommand?(phrase) }
    }

    // MARK: Wake word

    private func handleWakeTranscript(_ text: String, isFinal: Bool) {
        let lower = VoiceCommandStore.normalize(text)
        let wake = VoiceCommandStore.normalize(wakeWord)
        if !wake.isEmpty, let r = lower.range(of: wake, options: .backwards) {
            // Wake word heard — NOW show the overlay, and only the words spoken after it.
            if !wakeCapturing { wakeCapturing = true; onListeningChanged?(true) }
            wakeArmed = true
            pendingWakeCommand = String(lower[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            onPartial?(pendingWakeCommand)
            if isFinal {
                fireWakeCommand()
            } else if !pendingWakeCommand.isEmpty {
                armSilence(wakeSilenceTimeout)   // fire after a pause
            }
        } else if isFinal {
            recycleWakeWord()     // utterance ended without the wake word — start fresh
        }
        // No wake word yet → no overlay (stay quiet).
    }

    private func fireWakeCommand() {
        guard mode == .wakeWord, wakeArmed else { return }
        let cmd = pendingWakeCommand
        wakeArmed = false; pendingWakeCommand = ""
        if wakeCapturing { wakeCapturing = false; onListeningChanged?(false) }   // hide overlay
        if !cmd.isEmpty { onCommand?(cmd) }
        recycleWakeWord()
    }

    /// Recycle the recognition request/task so the transcript buffer resets (SFSpeech degrades over
    /// long sessions) — WITHOUT stopping the audio engine/tap, so listening continues seamlessly.
    /// Keeps `mode == .wakeWord`. Deferred to the next tick so the current callback fully unwinds.
    private func recycleWakeWord() {
        guard mode == .wakeWord else { return }
        silenceTimer?.invalidate(); silenceTimer = nil
        if wakeCapturing { wakeCapturing = false; onListeningChanged?(false) }   // hide overlay
        wakeArmed = false; pendingWakeCommand = ""; lastPartial = ""
        request?.endAudio(); request = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mode == .wakeWord else { return }
            if !self.startRecognition() {     // engine/tap stay up; just a fresh recogniser
                self.mode = .idle
                self.onListeningChanged?(false)
            }
        }
    }
}

import AVFoundation

/// Minimal text-to-speech for spoken notifications (e.g. "Slack message from Jeff"). Separate from
/// VoiceController (which does speech *recognition*); this only speaks. Utterances queue naturally,
/// so several announcements in a row play one after another rather than overlapping.
@MainActor
final class SpeechAnnouncer {
    private let synth = AVSpeechSynthesizer()

    /// 0…1 output volume and the speaking rate (defaults to the system's natural rate).
    var volume: Float = 1.0
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// Optional specific voice identifier; falls back to the en-US system voice.
    var voiceIdentifier: String?

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let u = AVSpeechUtterance(string: trimmed)
        u.rate = rate
        u.volume = volume
        u.voice = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(u)
    }

    /// Stop the current utterance and drop anything queued.
    func stop() { synth.stopSpeaking(at: .immediate) }

    /// An installed voice, for the settings picker.
    struct Voice: Identifiable, Hashable { let id: String; let label: String }

    /// English voices available on this system — the built-in ones plus any Enhanced/Premium the user
    /// downloaded in System Settings → Spoken Content. `speechVoices()` only returns voices that are
    /// actually installed, so voices that still need downloading are already excluded. Labelled with
    /// accent + quality, sorted for a picker.
    static func englishVoices() -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .map { v in
                let quality: String
                switch v.quality {
                case .premium:  quality = " · Premium"
                case .enhanced: quality = " · Enhanced"
                default:        quality = ""
                }
                return Voice(id: v.identifier, label: "\(v.name) (\(v.language))\(quality)")
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}

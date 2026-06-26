import Foundation

/// Decodes `T` if possible, else `nil` — lets an array skip elements that no longer decode (e.g. a
/// saved binding for a command that was removed) instead of failing the whole decode.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// A fixed app action a voice command can trigger. The set is fixed (each maps to an existing
/// coordinator method), but the spoken *phrases* that trigger it are user-editable (see `VoiceBinding`).
enum VoiceIntent: String, Codable, CaseIterable, Identifiable {
    case recenter, recalibrate, toggleStereo, toggleFocus, togglePassthrough
    case toggleHUD, toggleLabels, cursorToGaze, findCursor, screenshot, toggleRecording, toggleMicMute
    case windowPicker, help, brightnessUp, brightnessDown

    var id: String { rawValue }

    /// User-facing action name shown on the Voice Commands page.
    var title: String {
        switch self {
        case .recenter:        return "Recenter view"
        case .recalibrate:     return "Recalibrate drift"
        case .toggleStereo:    return "Stereo (SBS)"
        case .toggleFocus:     return "Focus looked-at screen"
        case .togglePassthrough: return "Passthrough"
        case .toggleHUD:       return "HUD widgets"
        case .toggleLabels:    return "Screen labels"
        case .cursorToGaze:    return "Cursor to gaze"
        case .findCursor:      return "Find the cursor"
        case .screenshot:      return "Screenshot"
        case .toggleRecording: return "Record"
        case .toggleMicMute:   return "Mute / unmute mic"
        case .windowPicker:    return "Move window to gaze"
        case .help:            return "Show help"
        case .brightnessUp:    return "Brightness up"
        case .brightnessDown:  return "Brightness down"
        }
    }

    /// Seeded trigger phrases (lowercase). Users can edit/add to these per command.
    var defaultPhrases: [String] {
        switch self {
        case .recenter:        return ["recenter", "recentre", "reset view", "center the view"]
        case .recalibrate:     return ["recalibrate", "calibrate drift"]
        case .toggleStereo:    return ["stereo", "side by side"]
        case .toggleFocus:     return ["focus", "focus screen"]
        case .togglePassthrough: return ["passthrough", "pass through"]
        case .toggleHUD:       return ["hud", "widgets"]
        case .toggleLabels:    return ["labels", "screen labels"]
        case .cursorToGaze:    return ["cursor to gaze", "move cursor here", "bring cursor"]
        case .findCursor:      return ["find cursor", "find the cursor", "where's my cursor", "find mouse"]
        case .screenshot:      return ["screenshot", "take a screenshot"]
        case .toggleRecording: return ["record", "start recording", "stop recording"]
        case .toggleMicMute:   return ["mute", "unmute"]
        case .windowPicker:    return ["move window", "window to gaze"]
        case .help:            return ["help", "show shortcuts"]
        case .brightnessUp:    return ["brighter", "brightness up"]
        case .brightnessDown:  return ["dimmer", "brightness down"]
        }
    }

    /// Commands that don't strictly need a gaze/render context. (Voice is only usable while AR runs,
    /// so this mostly matters for messaging.)
    var arGated: Bool {
        switch self {
        case .recalibrate, .help, .brightnessUp, .brightnessDown: return false
        default: return true
        }
    }
}

/// A user-editable binding: which spoken phrases trigger a given intent, and whether it's enabled.
struct VoiceBinding: Codable, Identifiable, Hashable {
    var id: UUID
    var intent: VoiceIntent
    var phrases: [String]
    var enabled: Bool

    init(id: UUID = UUID(), intent: VoiceIntent, phrases: [String], enabled: Bool = true) {
        self.id = id; self.intent = intent; self.phrases = phrases; self.enabled = enabled
    }
}

/// What a transcript resolved to.
enum VoiceMatch {
    case intent(VoiceIntent)
    case switchWorkspace(String)   // resolved workspace name
}

/// Owns the editable voice bindings and persists them. Mirrors `WorkspaceStore`'s JSON-in-Application
/// Support pattern. Seeds one binding per intent (from `defaultPhrases`) on first run, and tops up
/// any intents added in a later app version.
final class VoiceCommandStore {
    private(set) var bindings: [VoiceBinding]
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AR Workspace Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("voiceCommands.json")

        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([FailableDecodable<VoiceBinding>].self, from: data) {
            // Keep only bindings whose intent still exists (drops commands removed in a later version),
            // preserving the user's custom phrases for the ones that remain.
            bindings = saved.compactMap(\.value)
            let present = Set(bindings.map(\.intent))
            for intent in VoiceIntent.allCases where !present.contains(intent) {
                bindings.append(VoiceBinding(intent: intent, phrases: intent.defaultPhrases))
            }
        } else {
            bindings = Self.defaults()
        }
    }

    private static func defaults() -> [VoiceBinding] {
        VoiceIntent.allCases.map { VoiceBinding(intent: $0, phrases: $0.defaultPhrases) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(bindings) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func update(_ binding: VoiceBinding) {
        if let i = bindings.firstIndex(where: { $0.id == binding.id }) {
            bindings[i] = binding
            save()
        }
    }

    func resetToDefaults() {
        bindings = Self.defaults()
        save()
    }

    /// Resolve a transcript to an intent or a workspace switch. Returns nil if nothing matched.
    func match(_ transcript: String, workspaceNames: [String]) -> VoiceMatch? {
        let text = Self.normalize(transcript)
        guard !text.isEmpty else { return nil }

        // "switch to / go to / open / show <workspace>" → fuzzy match the remainder to a workspace.
        for prefix in ["switch to ", "switch ", "go to ", "open ", "show "] {
            if text.hasPrefix(prefix) {
                let target = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !target.isEmpty,
                   let name = workspaceNames.first(where: { Self.normalize($0).contains(target)
                                                            || target.contains(Self.normalize($0)) }) {
                    return .switchWorkspace(name)
                }
            }
        }

        // Otherwise: contains-match against enabled phrases, longest phrase first so multi-word
        // commands ("stop ar") win over their substrings ("stop"/"start ar").
        var candidates: [(phrase: String, intent: VoiceIntent)] = []
        for b in bindings where b.enabled {
            for p in b.phrases {
                let np = Self.normalize(p)
                if !np.isEmpty { candidates.append((np, b.intent)) }
            }
        }
        candidates.sort { $0.phrase.count > $1.phrase.count }
        if let hit = candidates.first(where: { text.contains($0.phrase) }) {
            return .intent(hit.intent)
        }

        // Fuzzy fallback: a phrase matches if every word in it appears (approximately) somewhere in
        // the transcript — absorbs mis-hearings like "re center" / "recentre" / "wreck order".
        let words = text.split(separator: " ").map(String.init)
        if let hit = candidates.first(where: { cand in
            let pw = cand.phrase.split(separator: " ").map(String.init)
            return !pw.isEmpty && pw.allSatisfy { p in words.contains { Self.fuzzyEqual($0, p) } }
        }) {
            return .intent(hit.intent)
        }
        return nil
    }

    /// Two words are "equal" if identical or within a small edit distance (scaled to length).
    static func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if abs(a.count - b.count) > 2 { return false }
        let tol = max(a.count, b.count) <= 4 ? 1 : 2
        return levenshtein(a, b) <= tol
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }

    /// Lowercase, strip punctuation, collapse whitespace.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " { return Character(scalar) }
            return " "
        }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }
}

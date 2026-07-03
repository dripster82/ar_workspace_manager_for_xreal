import Foundation

/// A release version with channel-aware precedence: `0.8.0-beta1` < `0.8.0-RC1` < `0.8.0`.
/// Parsed from release tags (with or without the leading V) and from CFBundleShortVersionString.
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    enum Channel: Int, Comparable {
        case beta = 0, rc = 1, stable = 2
        static func < (a: Channel, b: Channel) -> Bool { a.rawValue < b.rawValue }
    }

    var numbers: [Int]      // "0.8.0" → [0, 8, 0]
    var channel: Channel    // suffix-derived: -betaN → .beta, -RCN → .rc, none → .stable
    var preNumber: Int      // beta2 / RC2 → 2 (0 when absent)
    var raw: String         // original string, for display

    var description: String { raw }

    /// Parse "0.8.0", "0.8.0-RC2", "0.8.0-beta1", "V0.8.0-rc.1"… nil if there's no leading number.
    init?(_ string: String) {
        let s = string.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        guard let first = s.first, first.isNumber else { return nil }
        raw = s
        let parts = s.split(separator: "-", maxSplits: 1)
        numbers = parts[0].split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        if parts.count > 1 {
            let pre = parts[1].lowercased()
            channel = pre.hasPrefix("rc") ? .rc : .beta   // any other suffix counts as beta-grade
            preNumber = Int(pre.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)) ?? 0
        } else {
            channel = .stable
            preNumber = 0
        }
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        if a.channel != b.channel { return a.channel < b.channel }
        return a.preNumber < b.preNumber
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// The update channel a user opts into (About page picker). Persisted.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, rc, beta
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stable: return "Stable"
        case .rc: return "Release candidates"
        case .beta: return "Betas"
        }
    }
    /// Whether a release of `channel` is offered on this update channel.
    func includes(_ channel: AppVersion.Channel) -> Bool {
        switch self {
        case .stable: return channel == .stable
        case .rc: return channel >= .rc
        case .beta: return true
        }
    }
}

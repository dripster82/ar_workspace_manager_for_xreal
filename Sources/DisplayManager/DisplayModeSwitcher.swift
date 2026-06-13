import CoreGraphics
import Foundation

/// Switches a real display (the glasses) between its mono and side-by-side
/// resolutions. SBS stereo needs macOS to actually output 3840×1080 so the
/// glasses can split the frame between the eyes.
public enum DisplayModeSwitcher {
    public struct ModeInfo {
        public let width: Int
        public let height: Int
        public let refresh: Double
    }

    /// All distinct resolutions the display advertises (for diagnostics/UI).
    public static func availableModes(_ displayID: CGDirectDisplayID) -> [ModeInfo] {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else { return [] }
        return modes.map { ModeInfo(width: $0.width, height: $0.height, refresh: $0.refreshRate) }
    }

    /// Switch to the widest mode matching `width`×`height` (highest refresh). Returns success.
    @discardableResult
    public static func switchTo(displayID: CGDirectDisplayID, width: Int, height: Int) -> Bool {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else { return false }
        let candidates = modes
            .filter { $0.width == width && $0.height == height }
            .sorted { $0.refreshRate > $1.refreshRate }
        guard let target = candidates.first else {
            NSLog("DisplayModeSwitcher: no \(width)×\(height) mode on display \(displayID)")
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        NSLog("DisplayModeSwitcher: switch \(displayID) → \(width)×\(height)@\(Int(target.refreshRate)) result=\(result.rawValue)")
        return result == .success
    }

    public static func hasMode(displayID: CGDirectDisplayID, width: Int, height: Int) -> Bool {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else { return false }
        return modes.contains { $0.width == width && $0.height == height }
    }
}

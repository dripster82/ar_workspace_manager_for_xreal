import ColorSync
import CoreGraphics
import Foundation

/// Sets a display's ICC colour profile (the same thing as System Settings → Displays → Color
/// Profile). The glasses' factory "Air 2" profile forces colorsync to convert every frame at the
/// render rate (60–98% CPU on the display path), which starves the present and causes judder;
/// switching to a standard profile like sRGB makes it ~passthrough and the stalls largely vanish.
public enum DisplayColorProfile: String, CaseIterable, Identifiable, Sendable {
    case auto          // leave the display's current profile untouched
    case sRGB
    case displayP3
    case adobeRGB
    case genericRGB
    case rec709
    case rec2020
    case dciP3

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto:       return "Auto (leave as-is)"
        case .sRGB:       return "sRGB"
        case .displayP3:  return "Display P3"
        case .adobeRGB:   return "Adobe RGB (1998)"
        case .genericRGB: return "Generic RGB"
        case .rec709:     return "Rec. 709"
        case .rec2020:    return "Rec. 2020"
        case .dciP3:      return "DCI P3"
        }
    }

    private var fileName: String? {
        switch self {
        case .auto:       return nil
        case .sRGB:       return "sRGB Profile.icc"
        case .displayP3:  return "Display P3.icc"
        case .adobeRGB:   return "AdobeRGB1998.icc"
        case .genericRGB: return "Generic RGB Profile.icc"
        case .rec709:     return "ITU-709.icc"
        case .rec2020:    return "ITU-2020.icc"
        case .dciP3:      return "DCI(P3) RGB.icc"
        }
    }

    private var profileURL: URL? {
        guard let fileName else { return nil }
        let url = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles").appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Profiles whose .icc file is actually present (for building the picker).
    public static var available: [DisplayColorProfile] {
        allCases.filter { $0 == .auto || $0.profileURL != nil }
    }

    /// Apply this profile to `displayID`. `.auto` is a no-op (leaves the current profile). The
    /// change persists like the System Settings one. Returns true on success / no-op.
    @discardableResult
    public func apply(to displayID: CGDirectDisplayID) -> Bool {
        guard displayID != 0 else { return false }
        guard let url = profileURL else { return true }   // .auto — leave alone
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else { return false }
        let settings: [CFString: Any] = [profileKey: url as CFURL]
        let ok = ColorSyncDeviceSetCustomProfiles(deviceClass, uuid, settings as CFDictionary)
        NSLog("DisplayColorProfile: set %@ on display %u -> %@", label, displayID, ok ? "ok" : "FAILED")
        return ok
    }
}

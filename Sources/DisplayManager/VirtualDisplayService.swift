import AppKit
import CPrivateDisplay
import CoreGraphics
import Foundation

/// How a screen is anchored in the AR scene.
public enum ScreenPlacement: String, Codable, Sendable {
    case anchored  // fixed in world-orientation space (stays put as you look around)
    case floating  // fixed in the field of view (head-locked; travels with the head)
}

/// The desktop background applied to a (virtual) screen. Because the screen content is the
/// captured macOS desktop — opaque, and in the glasses' additive optics black reads as
/// transparent — the only way to change what shows behind your windows is to set that virtual
/// display's macOS wallpaper. `transparent` = pure black, so the desktop area shows through the
/// glasses and only your windows float.
public enum ScreenBackgroundKind: String, Codable, Sendable {
    case `default`     // leave the macOS wallpaper untouched
    case color         // solid colour (see `hex`)
    case transparent   // pure black → see-through in the glasses
    case image         // an image file (see `imagePath`)
}

public struct ScreenBackground: Codable, Hashable, Sendable {
    public var kind: ScreenBackgroundKind
    /// "#RRGGBB" — used when `kind == .color`.
    public var hex: String
    /// Absolute path to an image file — used when `kind == .image`.
    public var imagePath: String?

    public init(kind: ScreenBackgroundKind = .default, hex: String = "#1E1E2E",
                imagePath: String? = nil) {
        self.kind = kind
        self.hex = hex
        self.imagePath = imagePath
    }
}

/// A virtual screen definition the user configures.
public struct VirtualScreenConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var width: Int
    public var height: Int
    public var hiDPI: Bool

    // Spatial placement in the AR scene.
    public var yawDegrees: Double      // negative = left of center
    public var pitchDegrees: Double
    public var distanceMeters: Double
    public var scale: Double           // apparent size multiplier
    public var curvatureRadius: Double // horizontal curve amount 0 = flat … 5 = max wrap
    public var autoCurveH: Bool        // horizontal curve follows natural sphere
    public var showInAR: Bool
    /// Persistent UUID of a physical display this (virtual) screen is mirrored onto, if any.
    public var mirrorToPhysical: String?
    /// Id of another virtual screen this one mirrors (shows the same content as), if any. The
    /// source must not itself be a mirror (no chains).
    public var mirrorOfVirtual: UUID?
    /// Anchored (world-fixed) or floating (head-locked).
    public var placement: ScreenPlacement
    /// Desktop background applied to this (virtual) screen's macOS wallpaper.
    public var background: ScreenBackground

    public init(id: UUID = UUID(), name: String, width: Int, height: Int, hiDPI: Bool = false,
                yawDegrees: Double = 0, pitchDegrees: Double = 0, distanceMeters: Double = 2.0,
                scale: Double = 1.0, curvatureRadius: Double = 0,
                autoCurveH: Bool = false, showInAR: Bool = true,
                mirrorToPhysical: String? = nil, mirrorOfVirtual: UUID? = nil,
                placement: ScreenPlacement = .anchored,
                background: ScreenBackground = ScreenBackground()) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.hiDPI = hiDPI
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.distanceMeters = distanceMeters
        self.scale = scale
        self.curvatureRadius = curvatureRadius
        self.autoCurveH = autoCurveH
        self.showInAR = showInAR
        self.mirrorToPhysical = mirrorToPhysical
        self.mirrorOfVirtual = mirrorOfVirtual
        self.placement = placement
        self.background = background
    }

    // Custom decoding so older saved workspaces (without the newer fields) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        hiDPI = try c.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? false
        yawDegrees = try c.decodeIfPresent(Double.self, forKey: .yawDegrees) ?? 0
        pitchDegrees = try c.decodeIfPresent(Double.self, forKey: .pitchDegrees) ?? 0
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 2.0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        curvatureRadius = try c.decodeIfPresent(Double.self, forKey: .curvatureRadius) ?? 0
        // Migrate the old single autoCurve flag if present.
        let legacyAuto = try c.decodeIfPresent(Bool.self, forKey: .autoCurve) ?? false
        autoCurveH = try c.decodeIfPresent(Bool.self, forKey: .autoCurveH) ?? legacyAuto
        showInAR = try c.decodeIfPresent(Bool.self, forKey: .showInAR) ?? true
        mirrorToPhysical = try c.decodeIfPresent(String.self, forKey: .mirrorToPhysical)
        mirrorOfVirtual = try c.decodeIfPresent(UUID.self, forKey: .mirrorOfVirtual)
        placement = try c.decodeIfPresent(ScreenPlacement.self, forKey: .placement) ?? .anchored
        background = try c.decodeIfPresent(ScreenBackground.self, forKey: .background) ?? ScreenBackground()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(hiDPI, forKey: .hiDPI)
        try c.encode(yawDegrees, forKey: .yawDegrees)
        try c.encode(pitchDegrees, forKey: .pitchDegrees)
        try c.encode(distanceMeters, forKey: .distanceMeters)
        try c.encode(scale, forKey: .scale)
        try c.encode(curvatureRadius, forKey: .curvatureRadius)
        try c.encode(autoCurveH, forKey: .autoCurveH)
        try c.encode(showInAR, forKey: .showInAR)
        try c.encodeIfPresent(mirrorToPhysical, forKey: .mirrorToPhysical)
        try c.encodeIfPresent(mirrorOfVirtual, forKey: .mirrorOfVirtual)
        try c.encode(placement, forKey: .placement)
        try c.encode(background, forKey: .background)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, width, height, hiDPI, yawDegrees, pitchDegrees, distanceMeters
        case scale, curvatureRadius, autoCurve, autoCurveH, showInAR, mirrorToPhysical
        case mirrorOfVirtual, placement, background
    }

    /// Default placement values (position/size/curve), independent of identity & resolution.
    public static let defaultYawDegrees: Double = 0
    public static let defaultPitchDegrees: Double = 0
    public static let defaultDistanceMeters: Double = 2.0
    public static let defaultScale: Double = 1.0
    public static let defaultCurvature: Double = 0

    /// Restore placement to defaults, keeping id, name, resolution, and AR visibility.
    public mutating func resetPlacement() {
        yawDegrees = Self.defaultYawDegrees
        pitchDegrees = Self.defaultPitchDegrees
        distanceMeters = Self.defaultDistanceMeters
        scale = Self.defaultScale
        curvatureRadius = Self.defaultCurvature
        autoCurveH = false
    }
}

/// A named workspace: a set of virtual screens plus per-physical-display AR settings.
public struct Workspace: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var virtualScreens: [VirtualScreenConfig]
    /// Physical displays (by persistent display UUID string) the user wants mirrored into AR,
    /// mapped to their placement config.
    public var physicalInAR: [String: VirtualScreenConfig]
    /// Head-locked HUD widgets (clock, power, …) floating in the field of view.
    public var widgets: [HUDWidget]
    /// Stack containers that lay out grouped widgets.
    public var stacks: [HUDStack]

    public init(id: UUID = UUID(), name: String,
                virtualScreens: [VirtualScreenConfig] = [],
                physicalInAR: [String: VirtualScreenConfig] = [:],
                widgets: [HUDWidget] = [], stacks: [HUDStack] = []) {
        self.id = id
        self.name = name
        self.virtualScreens = virtualScreens
        self.physicalInAR = physicalInAR
        self.widgets = widgets
        self.stacks = stacks
    }

    // Custom decoding so workspaces saved before widgets existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        virtualScreens = try c.decodeIfPresent([VirtualScreenConfig].self, forKey: .virtualScreens) ?? []
        physicalInAR = try c.decodeIfPresent([String: VirtualScreenConfig].self, forKey: .physicalInAR) ?? [:]
        widgets = try c.decodeIfPresent([HUDWidget].self, forKey: .widgets) ?? []
        stacks = try c.decodeIfPresent([HUDStack].self, forKey: .stacks) ?? []
    }
}

/// Creates/destroys CGVirtualDisplay instances (private API) for a workspace's screens.
@MainActor
public final class VirtualDisplayService {
    public private(set) var active: [UUID: (display: CGVirtualDisplay, displayID: CGDirectDisplayID)] = [:]

    public init() {}

    public static var isAvailable: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
    }

    /// Apple Silicon display controllers cap the pixel width of a single pipe (~6.7k);
    /// a 2× backing wider than this fails, so fall back to 1× for very wide screens.
    private static let maxHiDPIBackingWidth = 6144

    /// Base for slot-based serial numbers ("VR" = 0x5652). Each active virtual display gets the
    /// lowest free slot, so its serial — and therefore the CGDisplay UUID macOS derives from
    /// vendor/product/serial — comes from a small bounded pool (slot 0, 1, 2, …) instead of being
    /// unique per screen.
    private static let serialBase: UInt32 = 0x56520000
    /// Slot index reserved for each active screen id, freed on destroy so the pool stays compact.
    private var slotForID: [UUID: UInt32] = [:]

    /// Reserve (or reuse) the lowest free slot for `id`. Why slots and not a per-screen hash:
    /// WindowServer persists a saved arrangement (`DisplaySets`) for every distinct *combination*
    /// of display UUIDs it sees and never prunes them. Hashing each screen's UUID gave every screen
    /// ever created a unique identity, so the registry grew without bound (hundreds of stale
    /// configs → colorsync.displayservices re-parsing a huge plist at ~75% CPU). Bounding identities
    /// to slot 0…N means the same display-set recurs each session and WindowServer reuses one config.
    private func reserveSlot(for id: UUID) -> UInt32 {
        if let slot = slotForID[id] { return slot }
        let used = Set(slotForID.values)
        var slot: UInt32 = 0
        while used.contains(slot) { slot += 1 }
        slotForID[id] = slot
        return slot
    }

    public func create(_ config: VirtualScreenConfig) -> CGDirectDisplayID? {
        guard Self.isAvailable else { return nil }

        let hiDPI = config.hiDPI && (config.width * 2 <= Self.maxHiDPIBackingWidth)
        if config.hiDPI && !hiDPI {
            NSLog("VirtualDisplayService: '\(config.name)' too wide for HiDPI backing — using 1×")
        }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = config.name
        descriptor.maxPixelsWide = UInt32(config.width * (hiDPI ? 2 : 1))
        descriptor.maxPixelsHigh = UInt32(config.height * (hiDPI ? 2 : 1))
        // Approximate physical size at ~100 ppi so macOS picks sensible default scaling.
        descriptor.sizeInMillimeters = CGSize(width: Double(config.width) * 0.254,
                                              height: Double(config.height) * 0.254)
        // Bounded slot-based identity (see reserveSlot): the serial — and the CGDisplay UUID macOS
        // derives from it — is drawn from a small pool reused across screens and sessions, so
        // WindowServer's display registry doesn't accumulate a new saved arrangement per screen.
        descriptor.serialNum = Self.serialBase &+ reserveSlot(for: config.id)
        descriptor.productID = 0x5652 // "VR"
        descriptor.vendorID = 0x4444
        descriptor.queue = DispatchQueue.main
        descriptor.terminationHandler = { _, _ in }

        let display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        if hiDPI {
            settings.modes = [CGVirtualDisplayMode(width: UInt32(config.width * 2),
                                                   height: UInt32(config.height * 2),
                                                   refreshRate: 60)]
        } else {
            settings.modes = [CGVirtualDisplayMode(width: UInt32(config.width),
                                                   height: UInt32(config.height),
                                                   refreshRate: 60)]
        }
        guard display.apply(settings) else {
            NSLog("VirtualDisplayService: applySettings failed for \(config.name)")
            return nil
        }
        active[config.id] = (display, display.displayID)
        NSLog("VirtualDisplayService: created '\(config.name)' displayID=\(display.displayID)")
        return display.displayID
    }

    public func destroy(_ id: UUID) {
        active.removeValue(forKey: id) // releasing the object removes the display
        slotForID.removeValue(forKey: id) // free the slot for reuse
    }

    public func destroyAll() {
        active.removeAll()
        slotForID.removeAll()
    }

    public func displayID(for id: UUID) -> CGDirectDisplayID? {
        active[id]?.displayID
    }
}

/// A named HUD layout — a reusable set of widgets + stacks, selectable independently of the
/// workspace (so the same HUD can be used across workspaces).
public struct HUDProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var widgets: [HUDWidget]
    public var stacks: [HUDStack]
    public init(id: UUID = UUID(), name: String, widgets: [HUDWidget] = [], stacks: [HUDStack] = []) {
        self.id = id; self.name = name; self.widgets = widgets; self.stacks = stacks
    }
}

/// Persists workspaces as JSON in Application Support.
public final class WorkspaceStore {
    public private(set) var workspaces: [Workspace]
    public var activeWorkspaceID: UUID?
    public private(set) var hudProfiles: [HUDProfile]
    public var activeHUDProfileID: UUID?

    private let url: URL

    private struct Saved: Codable {
        var workspaces: [Workspace]
        var activeWorkspaceID: UUID?
        var hudProfiles: [HUDProfile]?
        var activeHUDProfileID: UUID?
    }

    public init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VRDesktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("workspaces.json")

        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            workspaces = saved.workspaces
            activeWorkspaceID = saved.activeWorkspaceID
            if let profiles = saved.hudProfiles, !profiles.isEmpty {
                hudProfiles = profiles
                activeHUDProfileID = saved.activeHUDProfileID ?? profiles.first?.id
            } else {
                // Migrate: one HUD profile per workspace that has a HUD, named "<workspace> HUD".
                var profiles: [HUDProfile] = []
                var activeID: UUID?
                for ws in workspaces where !(ws.widgets.isEmpty && ws.stacks.isEmpty) {
                    let p = HUDProfile(name: "\(ws.name) HUD", widgets: ws.widgets, stacks: ws.stacks)
                    profiles.append(p)
                    if ws.id == activeWorkspaceID { activeID = p.id }
                }
                if profiles.isEmpty { profiles = [HUDProfile(name: "Default")] }
                hudProfiles = profiles
                activeHUDProfileID = activeID ?? profiles.first?.id
            }
        } else {
            let defaultWS = Workspace(name: "Default", virtualScreens: [
                VirtualScreenConfig(name: "Main", width: 2560, height: 1440, hiDPI: true),
            ])
            workspaces = [defaultWS]
            activeWorkspaceID = defaultWS.id
            let p = HUDProfile(name: "Default")
            hudProfiles = [p]
            activeHUDProfileID = p.id
        }
    }

    public func save() {
        let saved = Saved(workspaces: workspaces, activeWorkspaceID: activeWorkspaceID,
                          hudProfiles: hudProfiles, activeHUDProfileID: activeHUDProfileID)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public var activeWorkspace: Workspace? {
        get { workspaces.first { $0.id == activeWorkspaceID } }
        set {
            guard let newValue, let i = workspaces.firstIndex(where: { $0.id == newValue.id }) else { return }
            workspaces[i] = newValue
        }
    }

    public var activeHUDProfile: HUDProfile? {
        get { hudProfiles.first { $0.id == activeHUDProfileID } }
        set {
            guard let nv = newValue, let i = hudProfiles.firstIndex(where: { $0.id == nv.id }) else { return }
            hudProfiles[i] = nv
        }
    }

    public func appendHUDProfile(_ profile: HUDProfile) { hudProfiles.append(profile) }
    public func removeHUDProfile(id: UUID) { hudProfiles.removeAll { $0.id == id } }

    // Id-based access (for editing a workspace/profile that isn't the active/displayed one).
    public func workspace(_ id: UUID?) -> Workspace? { workspaces.first { $0.id == id } }
    public func updateWorkspace(_ ws: Workspace) {
        if let i = workspaces.firstIndex(where: { $0.id == ws.id }) { workspaces[i] = ws }
    }
    public func hudProfile(_ id: UUID?) -> HUDProfile? { hudProfiles.first { $0.id == id } }
    public func updateHUDProfile(_ p: HUDProfile) {
        if let i = hudProfiles.firstIndex(where: { $0.id == p.id }) { hudProfiles[i] = p }
    }

    public func append(_ workspace: Workspace) {
        workspaces.append(workspace)
    }

    public func remove(id: UUID) {
        workspaces.removeAll { $0.id == id }
    }
}

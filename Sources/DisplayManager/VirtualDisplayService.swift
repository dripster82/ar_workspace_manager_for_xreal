import AppKit
import CPrivateDisplay
import CoreGraphics
import Foundation

/// How a screen is anchored in the AR scene.
public enum ScreenPlacement: String, Codable, Sendable {
    case anchored  // fixed in world-orientation space (stays put as you look around)
    case floating  // fixed in the field of view (head-locked; travels with the head)
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

    public init(id: UUID = UUID(), name: String, width: Int, height: Int, hiDPI: Bool = false,
                yawDegrees: Double = 0, pitchDegrees: Double = 0, distanceMeters: Double = 2.0,
                scale: Double = 1.0, curvatureRadius: Double = 0,
                autoCurveH: Bool = false, showInAR: Bool = true,
                mirrorToPhysical: String? = nil, mirrorOfVirtual: UUID? = nil,
                placement: ScreenPlacement = .anchored) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, width, height, hiDPI, yawDegrees, pitchDegrees, distanceMeters
        case scale, curvatureRadius, autoCurve, autoCurveH, showInAR, mirrorToPhysical
        case mirrorOfVirtual, placement
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

    @discardableResult
    /// Deterministic 32-bit serial from a screen's UUID (FNV-1a), stable across launches so the
    /// virtual display keeps one identity — and one reused ColorSync profile — instead of a new
    /// one every session.
    private static func stableSerial(for id: UUID) -> UInt32 {
        var hash: UInt32 = 2166136261
        let b = id.uuid
        for byte in [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7,
                     b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15] {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        return hash
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
        // Stable per-screen identity. config.id.hashValue is randomised every process launch, so
        // each session the virtual display looked like a brand-new monitor — macOS then generated
        // a fresh ColorSync profile each time and piled up hundreds in
        // /Library/ColorSync/Profiles/Displays/. Deriving the serial deterministically from the
        // screen's UUID (FNV-1a over its 16 bytes) keeps the identity stable across launches, so
        // macOS reuses one profile per screen instead of accumulating new ones.
        descriptor.serialNum = Self.stableSerial(for: config.id)
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
    }

    public func destroyAll() {
        active.removeAll()
    }

    public func displayID(for id: UUID) -> CGDirectDisplayID? {
        active[id]?.displayID
    }
}

/// Persists workspaces as JSON in Application Support.
public final class WorkspaceStore {
    public private(set) var workspaces: [Workspace]
    public var activeWorkspaceID: UUID?

    private let url: URL

    public init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VRDesktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("workspaces.json")

        struct Saved: Codable {
            var workspaces: [Workspace]
            var activeWorkspaceID: UUID?
        }
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            workspaces = saved.workspaces
            activeWorkspaceID = saved.activeWorkspaceID
        } else {
            let defaultWS = Workspace(name: "Default", virtualScreens: [
                VirtualScreenConfig(name: "Main", width: 2560, height: 1440, hiDPI: true),
            ])
            workspaces = [defaultWS]
            activeWorkspaceID = defaultWS.id
        }
    }

    public func save() {
        struct Saved: Codable {
            var workspaces: [Workspace]
            var activeWorkspaceID: UUID?
        }
        let saved = Saved(workspaces: workspaces, activeWorkspaceID: activeWorkspaceID)
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

    public func append(_ workspace: Workspace) {
        workspaces.append(workspace)
    }

    public func remove(id: UUID) {
        workspaces.removeAll { $0.id == id }
    }
}

import AppKit
import CPrivateDisplay
import CoreGraphics
import Foundation

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
    public var verticalCurve: Double   // vertical curve amount 0 = flat … 5 = max wrap
    public var autoCurve: Bool         // curve follows the natural sphere (radius = distance)
    public var showInAR: Bool

    public init(id: UUID = UUID(), name: String, width: Int, height: Int, hiDPI: Bool = false,
                yawDegrees: Double = 0, pitchDegrees: Double = 0, distanceMeters: Double = 2.0,
                scale: Double = 1.0, curvatureRadius: Double = 0, verticalCurve: Double = 0,
                autoCurve: Bool = false, showInAR: Bool = true) {
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
        self.verticalCurve = verticalCurve
        self.autoCurve = autoCurve
        self.showInAR = showInAR
    }

    // Custom decoding so workspaces saved before verticalCurve/autoCurve existed still load.
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
        verticalCurve = try c.decodeIfPresent(Double.self, forKey: .verticalCurve) ?? 0
        autoCurve = try c.decodeIfPresent(Bool.self, forKey: .autoCurve) ?? false
        showInAR = try c.decodeIfPresent(Bool.self, forKey: .showInAR) ?? true
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
        verticalCurve = 0
        autoCurve = false
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

    public init(id: UUID = UUID(), name: String,
                virtualScreens: [VirtualScreenConfig] = [],
                physicalInAR: [String: VirtualScreenConfig] = [:]) {
        self.id = id
        self.name = name
        self.virtualScreens = virtualScreens
        self.physicalInAR = physicalInAR
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

    @discardableResult
    public func create(_ config: VirtualScreenConfig) -> CGDirectDisplayID? {
        guard Self.isAvailable else { return nil }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = config.name
        descriptor.maxPixelsWide = UInt32(config.width * (config.hiDPI ? 2 : 1))
        descriptor.maxPixelsHigh = UInt32(config.height * (config.hiDPI ? 2 : 1))
        // Approximate physical size at ~100 ppi so macOS picks sensible default scaling.
        descriptor.sizeInMillimeters = CGSize(width: Double(config.width) * 0.254,
                                              height: Double(config.height) * 0.254)
        descriptor.serialNum = UInt32(truncatingIfNeeded: config.id.hashValue)
        descriptor.productID = 0x5652 // "VR"
        descriptor.vendorID = 0x4444
        descriptor.queue = DispatchQueue.main
        descriptor.terminationHandler = { _, _ in }

        let display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0
        if config.hiDPI {
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
                VirtualScreenConfig(name: "Main", width: 2560, height: 1440),
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

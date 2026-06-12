import AppKit
import CapturePipeline
import Compositor
import DisplayManager
import GlassesDriver
import SwiftUI
import simd

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var glassesState: GlassesState = .disconnected
    @Published var imuRate: Double = 0
    @Published var renderFPS: Double = 0
    @Published var euler: (yaw: Double, pitch: Double, roll: Double) = (0, 0, 0)
    @Published var arActive = false
    @Published var outputScreenName: String?
    @Published var statusMessage = ""

    // Tracking-feel tuning (live, persisted in UserDefaults).
    @Published var orientationSmoothingMs: Double = 42 {
        didSet { IMUService.shared.orientationTimeConstant = Float(orientationSmoothingMs / 1000)
                 UserDefaults.standard.set(orientationSmoothingMs, forKey: "orientationSmoothingMs") }
    }
    @Published var velocitySmoothingMs: Double = 84 {
        didSet { IMUService.shared.velocityTimeConstant = Float(velocitySmoothingMs / 1000)
                 UserDefaults.standard.set(velocitySmoothingMs, forKey: "velocitySmoothingMs") }
    }
    @Published var predictionLeadMs: Double = 21 {
        didSet { renderer?.predictionLead = Float(predictionLeadMs / 1000)
                 UserDefaults.standard.set(predictionLeadMs, forKey: "predictionLeadMs") }
    }

    // Fake pose for glasses-free testing.
    @Published var useFakePose = false { didSet { applyFakePose() } }
    @Published var fakeYawDegrees: Double = 0 { didSet { applyFakePose() } }
    @Published var fakePitchDegrees: Double = 0 { didSet { applyFakePose() } }

    let workspaceStore = WorkspaceStore()
    let virtualDisplays = VirtualDisplayService()
    private(set) var renderer: GlassesRenderer?
    private var captures: [UUID: CaptureSource] = [:]
    private var statsTimer: Timer?
    private var lastSampleCount: UInt64 = 0

    init() {
        renderer = GlassesRenderer(poseStore: IMUService.shared.poseStore)
        IMUService.shared.stateChanged = { [weak self] state in
            Task { @MainActor in self?.glassesState = state }
        }
        IMUService.shared.start()

        let defaults = UserDefaults.standard
        if defaults.object(forKey: "orientationSmoothingMs") != nil {
            orientationSmoothingMs = defaults.double(forKey: "orientationSmoothingMs")
        }
        if defaults.object(forKey: "velocitySmoothingMs") != nil {
            velocitySmoothingMs = defaults.double(forKey: "velocitySmoothingMs")
        }
        if defaults.object(forKey: "predictionLeadMs") != nil {
            predictionLeadMs = defaults.double(forKey: "predictionLeadMs")
        }

        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStats() }
        }
    }

    private func updateStats() {
        let count = IMUService.shared.poseStore.sampleCount
        imuRate = Double(count &- lastSampleCount) * 2
        lastSampleCount = count
        renderFPS = renderer?.framesPerSecond ?? 0

        let q = IMUService.shared.poseStore.latest().orientation
        let toDeg = 180.0 / Double.pi
        euler = (
            yaw: Double(atan2f(2 * (q.real * q.imag.y + q.imag.x * q.imag.z),
                               1 - 2 * (q.imag.y * q.imag.y + q.imag.x * q.imag.x))) * toDeg,
            pitch: Double(asinf(max(-1, min(1, 2 * (q.real * q.imag.x - q.imag.y * q.imag.z))))) * toDeg,
            roll: Double(atan2f(2 * (q.real * q.imag.z + q.imag.x * q.imag.y),
                                1 - 2 * (q.imag.x * q.imag.x + q.imag.z * q.imag.z))) * toDeg
        )
    }

    private func applyFakePose() {
        guard let renderer else { return }
        if useFakePose {
            let yaw = simd_quatf(angle: Float(fakeYawDegrees * .pi / 180), axis: SIMD3(0, 1, 0))
            let pitch = simd_quatf(angle: Float(fakePitchDegrees * .pi / 180), axis: SIMD3(1, 0, 0))
            renderer.fakePose = yaw * pitch
        } else {
            renderer.fakePose = nil
        }
    }

    func recenter() { IMUService.shared.recenter() }

    // MARK: Output screen selection

    /// The glasses show up as an external display named like "Air"; otherwise any
    /// non-main external screen works as a stand-in for testing.
    var candidateOutputScreens: [NSScreen] {
        NSScreen.screens.filter { $0 != NSScreen.main || NSScreen.screens.count == 1 }
    }

    static func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    // MARK: AR session

    func startAR(on screen: NSScreen) {
        guard let renderer, !arActive else { return }
        guard let workspace = workspaceStore.activeWorkspace else { return }

        let outputDisplayID = Self.screenDisplayID(screen)

        // 1. Create virtual displays for the workspace.
        var sceneScreens: [SceneScreen] = []
        for config in workspace.virtualScreens where config.showInAR {
            guard let displayID = virtualDisplays.create(config) ?? nil else {
                statusMessage = "CGVirtualDisplay unavailable — \(config.name) skipped"
                continue
            }
            guard displayID != outputDisplayID else { continue } // never capture the glasses display
            sceneScreens.append(makeSceneScreen(config: config, captureDisplayID: displayID))
        }

        // 2. Physical displays mirrored into AR.
        for (uuidString, config) in workspace.physicalInAR where config.showInAR {
            guard let displayID = Self.resolvePhysicalDisplay(uuidString: uuidString),
                  displayID != outputDisplayID else { continue }
            sceneScreens.append(makeSceneScreen(config: config, captureDisplayID: displayID))
        }

        renderer.setScreens(sceneScreens)
        renderer.startOutput(on: screen)
        outputScreenName = screen.localizedName
        arActive = true
        statusMessage = "AR active on \(screen.localizedName) with \(sceneScreens.count) screen(s)"
    }

    private func makeSceneScreen(config: VirtualScreenConfig, captureDisplayID: CGDirectDisplayID) -> SceneScreen {
        let capture = CaptureSource(displayID: captureDisplayID, device: renderer!.device)
        captures[config.id] = capture
        Task {
            do { try await capture.start() }
            catch { await MainActor.run { self.statusMessage = "Capture failed for \(config.name): \(error.localizedDescription)" } }
        }
        // Apparent width: ~1.6m per 1920px at scale 1, 2m away.
        let baseWidth = Float(config.width) / 1920.0 * 1.6 * Float(config.scale)
        return SceneScreen(
            id: config.id,
            yaw: Float(config.yawDegrees * .pi / 180),
            pitch: Float(config.pitchDegrees * .pi / 180),
            distance: Float(config.distanceMeters),
            widthMeters: baseWidth,
            aspect: Float(config.width) / Float(config.height),
            curvatureRadius: Float(config.curvatureRadius),
            textureProvider: { [weak capture] in capture?.latestTexture }
        )
    }

    static func resolvePhysicalDisplay(uuidString: String) -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            let id = screenDisplayID(screen)
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
               CFUUIDCreateString(nil, uuid) as String == uuidString {
                return id
            }
        }
        return nil
    }

    func stopAR() {
        guard arActive else { return }
        renderer?.stopOutput()
        renderer?.setScreens([])
        let activeCaptures = captures.values
        captures.removeAll()
        Task { for c in activeCaptures { await c.stop() } }
        virtualDisplays.destroyAll()
        arActive = false
        outputScreenName = nil
        statusMessage = "AR stopped"
    }

    func saveWorkspaces() { workspaceStore.save() }
}

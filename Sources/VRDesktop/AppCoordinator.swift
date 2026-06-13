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
    @Published var outputWindowInfo: String = "—"
    @Published var screenList: [String] = []
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
            Task { @MainActor in
                self?.glassesState = state
                if case .connected = state {
                    self?.refreshBrightness()
                } else {
                    self?.brightnessAvailable = false
                    MCUService.shared.disconnect()
                }
            }
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

        refreshMirroringState()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshMirroringState() }
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

        refreshPermissions()
        if let info = renderer?.outputWindowInfo {
            outputWindowInfo = "window \(Int(info.frame.width))×\(Int(info.frame.height)) at (\(Int(info.frame.origin.x)),\(Int(info.frame.origin.y))) on \(info.screenName)"
        } else {
            outputWindowInfo = "—"
        }
        screenList = NSScreen.screens.map {
            "\($0.localizedName): \(Int($0.frame.width))×\(Int($0.frame.height)) at (\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y))) scale \($0.backingScaleFactor)"
        }

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

    @Published var recenterRoll: Bool = UserDefaults.standard.object(forKey: "recenterRoll") == nil
        ? true : UserDefaults.standard.bool(forKey: "recenterRoll") {
        didSet { UserDefaults.standard.set(recenterRoll, forKey: "recenterRoll") }
    }

    func recenter() { IMUService.shared.recenter(includeRoll: recenterRoll) }

    // MARK: Glasses brightness (0–7)

    @Published var glassesBrightness: Double = 4
    @Published var brightnessAvailable = false

    func refreshBrightness() {
        MCUService.shared.brightness { value in
            Task { @MainActor in
                if let value {
                    self.glassesBrightness = Double(value)
                    self.brightnessAvailable = true
                } else {
                    self.brightnessAvailable = false
                }
            }
        }
    }

    func applyBrightness() {
        MCUService.shared.setBrightness(Int(glassesBrightness.rounded())) { ok in
            if !ok {
                Task { @MainActor in self.statusMessage = "Setting brightness failed — glasses connected?" }
            }
        }
    }

    // MARK: Stereo / SBS (experimental)

    @Published var stereoEnabled = false
    @Published var ipdMillimeters: Double = 63 {
        didSet { renderer?.ipd = Float(ipdMillimeters / 1000) }
    }
    private var glassesDisplayID: CGDirectDisplayID = 0

    var sbsModeAvailable: Bool {
        glassesDisplayID != 0 &&
        DisplayModeSwitcher.hasMode(displayID: glassesDisplayID, width: 3840, height: 1080)
    }

    func setStereo(_ on: Bool) {
        guard let renderer, arActive, glassesDisplayID != 0 else {
            stereoEnabled = false
            return
        }
        if on {
            MCUService.shared.setDisplayMode(.sbs3840x1080_60) { ok in
                Task { @MainActor in
                    if !ok { self.statusMessage = "Glasses didn't accept SBS mode" }
                }
            }
            // Give the glasses a moment to renegotiate, then drive 3840×1080 from macOS.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                let switched = DisplayModeSwitcher.switchTo(displayID: self.glassesDisplayID,
                                                            width: 3840, height: 1080)
                renderer.stereoEnabled = true
                self.stereoEnabled = true
                self.statusMessage = switched
                    ? "SBS stereo on (3840×1080)"
                    : "SBS rendering on, but no 3840×1080 macOS mode — image may be squished"
            }
        } else {
            renderer.stereoEnabled = false
            stereoEnabled = false
            DisplayModeSwitcher.switchTo(displayID: glassesDisplayID, width: 1920, height: 1080)
            MCUService.shared.setDisplayMode(.mono1080p60)
            statusMessage = "SBS stereo off"
        }
    }

    // MARK: Display mirroring

    /// True when any online display is mirroring another (e.g. the glasses arrived
    /// in macOS's default mirror mode instead of extending the desktop).
    @Published var mirroringActive = false
    @Published var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()

    func refreshPermissions() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    /// First click: trigger the system permission request — this registers the app in
    /// the Screen Recording list and shows the system prompt. If permission still isn't
    /// granted on a later click (prompt dismissed/denied), open the Settings pane.
    func requestScreenRecordingPermission() {
        let alreadyAsked = UserDefaults.standard.bool(forKey: "askedScreenRecording")
        let granted = CGRequestScreenCaptureAccess()
        UserDefaults.standard.set(true, forKey: "askedScreenRecording")
        if !granted && alreadyAsked {
            let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
        if !granted {
            statusMessage = "After granting Screen Recording, quit and relaunch the app"
        }
        refreshPermissions()
    }

    func refreshMirroringState() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        mirroringActive = ids.prefix(Int(count)).contains {
            CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay
        }
    }

    /// Break all mirroring so every display (glasses included) is an extended desktop.
    /// Returns true if the configuration was changed (the screen list will rebuild async).
    @discardableResult
    func stopMirroring() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        var changed = false
        for id in ids.prefix(Int(count)) where CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay {
            CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
            changed = true
        }
        if changed {
            CGCompleteDisplayConfiguration(config, .permanently)
            statusMessage = "Mirroring disabled — displays are now extended"
        } else {
            CGCancelDisplayConfiguration(config)
        }
        refreshMirroringState()
        return changed
    }

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
        guard !arActive else { return }
        let targetID = Self.screenDisplayID(screen)
        let targetName = screen.localizedName

        // Glasses must be an extended display. If we just broke mirroring, the screen
        // list rebuilds asynchronously and `screen` is stale — wait, then re-resolve.
        if stopMirroring() {
            statusMessage = "Reconfiguring displays…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                let resolved = NSScreen.screens.first { Self.screenDisplayID($0) == targetID }
                    ?? NSScreen.screens.first { $0.localizedName == targetName }
                    ?? NSScreen.screens.first { $0 != NSScreen.main }
                if let resolved {
                    self.beginAR(on: resolved)
                } else {
                    self.statusMessage = "Couldn't find output screen after un-mirroring — pick it again"
                }
            }
            return
        }
        beginAR(on: screen)
    }

    private func beginAR(on screen: NSScreen) {
        guard let renderer, !arActive else { return }
        guard let workspace = workspaceStore.activeWorkspace else { return }

        let outputDisplayID = Self.screenDisplayID(screen)
        glassesDisplayID = outputDisplayID

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
        arActive = true
        statusMessage = "Waiting for displays to settle…"

        // Adding the virtual displays just re-arranged the global screen layout
        // (they get inserted into the arrangement, shifting the glasses' origin).
        // Re-resolve the output screen by ID once things settle, then open the window.
        let screenCount = sceneScreens.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.arActive else { return }
            let target = NSScreen.screens.first { Self.screenDisplayID($0) == outputDisplayID } ?? screen
            renderer.startOutput(on: target)
            self.outputScreenName = target.localizedName
            self.statusMessage = "AR active on \(target.localizedName) \(Int(target.frame.width))×\(Int(target.frame.height)) at (\(Int(target.frame.origin.x)),\(Int(target.frame.origin.y))) with \(screenCount) screen(s)"
        }
    }

    private func makeSceneScreen(config: VirtualScreenConfig, captureDisplayID: CGDirectDisplayID) -> SceneScreen {
        let capture = CaptureSource(displayID: captureDisplayID, device: renderer!.device)
        captures[config.id] = capture
        Task {
            do { try await capture.start() }
            catch { await MainActor.run { self.statusMessage = "Capture failed for \(config.name): \(error.localizedDescription)" } }
        }
        return sceneScreen(config: config, capture: capture)
    }

    /// Build the placement geometry for a screen, reusing an existing capture.
    private func sceneScreen(config: VirtualScreenConfig, capture: CaptureSource) -> SceneScreen {
        // Apparent width: ~1.6m per 1920px at scale 1, 2m away.
        let baseWidth = Float(config.width) / 1920.0 * 1.6 * Float(config.scale)
        return SceneScreen(
            id: config.id,
            yaw: Float(config.yawDegrees * .pi / 180),
            pitch: Float(config.pitchDegrees * .pi / 180),
            distance: Float(config.distanceMeters),
            widthMeters: baseWidth,
            aspect: Float(config.width) / Float(config.height),
            curveAmount: Float(config.curvatureRadius),
            textureProvider: { [weak capture] in capture?.latestTexture }
        )
    }

    /// Rebuild the live scene from the active workspace's current placement values,
    /// reusing existing captures so a slider drag updates the AR view in real time.
    /// (Adding/removing screens or toggling "show in AR" still needs a Start/Stop.)
    func liveUpdateScreens() {
        guard let renderer, arActive,
              let workspace = workspaceStore.activeWorkspace else { return }
        var sceneScreens: [SceneScreen] = []
        for config in workspace.virtualScreens where config.showInAR {
            if let capture = captures[config.id] {
                sceneScreens.append(sceneScreen(config: config, capture: capture))
            }
        }
        for (_, config) in workspace.physicalInAR where config.showInAR {
            if let capture = captures[config.id] {
                sceneScreens.append(sceneScreen(config: config, capture: capture))
            }
        }
        renderer.setScreens(sceneScreens)
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
        if stereoEnabled {
            renderer?.stereoEnabled = false
            stereoEnabled = false
            if glassesDisplayID != 0 {
                DisplayModeSwitcher.switchTo(displayID: glassesDisplayID, width: 1920, height: 1080)
            }
            MCUService.shared.setDisplayMode(.mono1080p60)
        }
        renderer?.stopOutput()
        renderer?.setScreens([])
        let activeCaptures = captures.values
        captures.removeAll()
        Task { for c in activeCaptures { await c.stop() } }
        virtualDisplays.destroyAll()
        glassesDisplayID = 0
        arActive = false
        outputScreenName = nil
        statusMessage = "AR stopped"
    }

    func saveWorkspaces() { workspaceStore.save() }

    func moveOutputWindow(x: Double, y: Double) {
        renderer?.moveOutput(to: CGPoint(x: x, y: y))
    }
}

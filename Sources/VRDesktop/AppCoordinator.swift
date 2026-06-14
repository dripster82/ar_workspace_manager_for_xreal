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

    // Tracking-feel tuning (One-Euro filter; live, persisted in UserDefaults).
    @Published var minCutoffHz: Double = 1.0 {            // lower = calmer at rest
        didSet { IMUService.shared.minCutoff = Float(minCutoffHz)
                 UserDefaults.standard.set(minCutoffHz, forKey: "minCutoffHz") }
    }
    @Published var betaResponsiveness: Double = 0.5 {     // higher = less lag when turning
        didSet { IMUService.shared.beta = Float(betaResponsiveness)
                 UserDefaults.standard.set(betaResponsiveness, forKey: "beta") }
    }
    @Published var predictionLeadMs: Double = 21 {
        didSet { renderer?.predictionLead = Float(predictionLeadMs / 1000)
                 UserDefaults.standard.set(predictionLeadMs, forKey: "predictionLeadMs") }
    }

    // Image quality.
    @Published var antialiasLevel: Int = 4 {   // 1 (off), 2, 4, 8
        didSet {
            renderer?.setSampleCount(antialiasLevel)
            // Reflect any GPU clamp (e.g. 8× unsupported → 4×) back into the control.
            if let applied = renderer?.sampleCount, applied != antialiasLevel {
                antialiasLevel = applied
                return
            }
            UserDefaults.standard.set(antialiasLevel, forKey: "antialiasLevel")
        }
    }
    var supportedAALevels: [Int] { renderer?.supportedSampleCounts() ?? [1, 2, 4] }
    @Published var sharpenLevel: Int = 1 {   // 1 (off), 2, 4, 8, 16
        didSet { renderer?.setSharpenAnisotropy(sharpenLevel)
                 UserDefaults.standard.set(sharpenLevel, forKey: "sharpenLevel") }
    }
    @Published var renderScalePercent: Int = 100 {   // 100 = off, 125, 150, 200 (supersample)
        didSet { renderer?.setRenderScale(Double(renderScalePercent) / 100)
                 UserDefaults.standard.set(renderScalePercent, forKey: "renderScalePercent") }
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
    private let cursorConfiner = CursorConfiner()
    // Held while AR runs: prevents App Nap / timer coalescing from throttling the render
    // display link (the glasses window is never frontmost, so the app looks "idle" to macOS).
    private var arActivity: NSObjectProtocol?

    /// Wide curved canvas (mono only): lay all anchored screens onto one continuous
    /// auto-curved surface at a single shared distance and scale, in their picked positions.
    @Published var wideCanvas: Bool = UserDefaults.standard.bool(forKey: "wideCanvas") {
        didSet {
            UserDefaults.standard.set(wideCanvas, forKey: "wideCanvas")
            liveUpdateScreens()
        }
    }

    /// Keep the cursor off the AR output display while AR runs.
    @Published var confineCursor: Bool = UserDefaults.standard.object(forKey: "confineCursor") == nil
        ? true : UserDefaults.standard.bool(forKey: "confineCursor") {
        didSet {
            UserDefaults.standard.set(confineCursor, forKey: "confineCursor")
            updateCursorConfinement()
        }
    }

    /// Write detailed troubleshooting info to debug.log.
    @Published var debugLogging: Bool = UserDefaults.standard.bool(forKey: "debugLogging") {
        didSet {
            UserDefaults.standard.set(debugLogging, forKey: "debugLogging")
            DebugLog.shared.setEnabled(debugLogging)
        }
    }
    /// Login-item state, shared by the control panel and the menu bar.
    @Published var launchAtLogin: Bool = LaunchAtLogin.isEnabled {
        didSet { LaunchAtLogin.set(launchAtLogin) }
    }

    /// Live raw-vs-filtered IMU logging (~60 Hz) for head-movement / calibration testing.
    @Published var rawIMULogging = false {
        didSet {
            if rawIMULogging { DebugLog.shared.setEnabled(true) }
            IMUService.shared.rawLog = { DebugLog.shared.log($0) }
            IMUService.shared.rawLoggingEnabled = rawIMULogging
            renderer?.frameLog = { DebugLog.shared.log($0) }
            renderer?.frameLoggingEnabled = rawIMULogging
            let msg = rawIMULogging ? "=== raw IMU logging on ===" : "=== raw IMU logging off ==="
            DebugLog.shared.log(msg)
        }
    }

    var debugLogURL: URL { DebugLog.shared.fileURL }
    func revealDebugLog() { NSWorkspace.shared.activateFileViewerSelecting([DebugLog.shared.fileURL]) }
    func clearDebugLog() { DebugLog.shared.clear() }
    private var lastLogSnapshot: TimeInterval = 0

    /// The screen the user is currently looking at (gaze nearest its centre), if any.
    @Published var lookedAtScreenID: UUID?
    @Published var lookedAtScreenName: String?

    init() {
        if UserDefaults.standard.bool(forKey: "debugLogging") { DebugLog.shared.setEnabled(true) }
        DebugLog.shared.log("App launched")
        renderer = GlassesRenderer(poseStore: IMUService.shared.poseStore)
        IMUService.shared.stateChanged = { [weak self] state in
            Task { @MainActor in
                self?.glassesState = state
                DebugLog.shared.log("Glasses state: \(state)")
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
        if defaults.object(forKey: "minCutoffHz") != nil {
            minCutoffHz = defaults.double(forKey: "minCutoffHz")
        }
        if defaults.object(forKey: "beta") != nil {
            betaResponsiveness = defaults.double(forKey: "beta")
        }
        if defaults.object(forKey: "predictionLeadMs") != nil {
            predictionLeadMs = defaults.double(forKey: "predictionLeadMs")
        }
        // Push initial values into the filter.
        IMUService.shared.minCutoff = Float(minCutoffHz)
        IMUService.shared.beta = Float(betaResponsiveness)

        if defaults.object(forKey: "antialiasLevel") != nil {
            antialiasLevel = defaults.integer(forKey: "antialiasLevel")
        }
        if defaults.object(forKey: "sharpenLevel") != nil {
            sharpenLevel = defaults.integer(forKey: "sharpenLevel")
        }
        if defaults.object(forKey: "renderScalePercent") != nil {
            renderScalePercent = defaults.integer(forKey: "renderScalePercent")
        }
        renderer?.setSampleCount(antialiasLevel)
        renderer?.setSharpenAnisotropy(sharpenLevel)
        renderer?.setRenderScale(Double(renderScalePercent) / 100)

        refreshMirroringState()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMirroringState()
                self?.handleScreenChange()
            }
        }

        // Recover the AR session across sleep/wake (captures and displays drop out).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemWake() }
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

        updateLookedAtScreen()

        // Reflect brightness changed via the glasses' own buttons (unless mid-drag).
        if brightnessAvailable, !editingBrightness {
            MCUService.shared.pollBrightness { value in
                guard let value else { return }
                Task { @MainActor in
                    if !self.editingBrightness, Int(self.glassesBrightness) != value {
                        self.glassesBrightness = Double(value)
                    }
                }
            }
        }

        // Periodic snapshot (~every 2s) for drift/perf troubleshooting.
        let now = CACurrentMediaTime()
        if debugLogging, now - lastLogSnapshot >= 2.0 {
            lastLogSnapshot = now
            let snapshot = String(
                format: "snapshot imu=%.0fHz fps=%.0f yaw=%+.1f pitch=%+.1f roll=%+.1f ar=%@ stereo=%@ look=%@",
                imuRate, renderFPS, euler.yaw, euler.pitch, euler.roll,
                arActive ? "on" : "off", stereoEnabled ? "on" : "off",
                lookedAtScreenName ?? "-")
            DebugLog.shared.log(snapshot)
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

    @Published var glassesBrightness: Double = 4 // device value 0–7
    @Published var brightnessAvailable = false
    var editingBrightness = false // suppress polling while the user drags the slider

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

    /// Step glasses brightness up/down by one (0–7), used by the ⌃⌥+brightness hotkey.
    func adjustBrightness(up: Bool) {
        guard brightnessAvailable else { return }
        glassesBrightness = min(8, max(0, glassesBrightness + (up ? 1 : -1)))
        applyBrightness()
    }

    // MARK: Stereo / SBS (experimental)

    @Published var stereoEnabled = false
    @Published var ipdMillimeters: Double = 63 {
        didSet { renderer?.ipd = Float(ipdMillimeters / 1000) }
    }
    private var glassesDisplayID: CGDirectDisplayID = 0
    private var lastOutputScreenID: CGDirectDisplayID = 0

    var sbsModeAvailable: Bool {
        glassesDisplayID != 0 &&
        DisplayModeSwitcher.hasMode(displayID: glassesDisplayID, width: 3840, height: 1080)
    }

    func setStereo(_ on: Bool) {
        let stereoLog = "setStereo(\(on)) arActive=\(arActive) sbsModeAvailable=\(sbsModeAvailable)"
        DebugLog.shared.log(stereoLog)
        guard let renderer, arActive, glassesDisplayID != 0 else {
            stereoEnabled = false
            return
        }
        // Tear the output (CAMetalDisplayLink) down BEFORE reconfiguring the display — a live
        // display link against a display whose mode changes underneath it crashes QuartzCore.
        switchingDisplayMode = true
        renderer.stopOutput()
        renderer.stereoEnabled = on
        stereoEnabled = on

        if on {
            MCUService.shared.setDisplayMode(.sbs3840x1080_60) { ok in
                Task { @MainActor in
                    if !ok { self.statusMessage = "Glasses didn't accept SBS mode" }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                let switched = DisplayModeSwitcher.switchTo(displayID: self.glassesDisplayID,
                                                            width: 3840, height: 1080)
                self.statusMessage = switched
                    ? "SBS stereo on (3840×1080)"
                    : "SBS rendering on, but no 3840×1080 macOS mode — image may be squished"
                DebugLog.shared.log("SBS on: macOS 3840x1080 switch=\(switched)")
                self.restartOutputOnGlasses(after: 1.0)
            }
        } else {
            DisplayModeSwitcher.switchTo(displayID: glassesDisplayID, width: 1920, height: 1080)
            MCUService.shared.setDisplayMode(.mono1080p60)
            statusMessage = "SBS stereo off"
            restartOutputOnGlasses(after: 1.0)
        }
    }

    /// Rebuild the AR output (and its display link) on the glasses once the display mode
    /// has settled after an SBS switch.
    private func restartOutputOnGlasses(after delay: Double, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.arActive, let renderer = self.renderer else {
                self?.switchingDisplayMode = false; return
            }
            // After a display-mode switch the screen list can stay stale for a while; retry
            // until the glasses reappear at the new mode instead of dropping the AR window.
            guard let screen = NSScreen.screens.first(where: {
                Self.screenDisplayID($0) == self.glassesDisplayID
            }) else {
                if attempt < 12 {
                    self.restartOutputOnGlasses(after: 0.3, attempt: attempt + 1)
                } else {
                    DebugLog.shared.log("restartOutput: glasses screen not found after retries")
                    self.switchingDisplayMode = false
                }
                return
            }
            renderer.startOutput(on: screen)
            self.applyConfiguredMirrors()
            self.updateCursorConfinement()
            DebugLog.shared.log("restartOutput: started on '\(screen.localizedName)' \(NSStringFromRect(screen.frame))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.switchingDisplayMode = false }
        }
    }

    // MARK: Display mirroring

    /// True when any online display is mirroring another (e.g. the glasses arrived
    /// in macOS's default mirror mode instead of extending the desktop).
    @Published var mirroringActive = false
    @Published var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    @Published var hasAccessibilityPermission = BrightnessHotKey.accessibilityTrusted(prompt: false)

    func refreshPermissions() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        hasAccessibilityPermission = BrightnessHotKey.accessibilityTrusted(prompt: false)
    }

    /// Trigger the Screen Recording system prompt (allow/deny). The OS dialog itself offers
    /// to open Settings, so we never open it ourselves.
    func requestScreenRecordingPermission() {
        if !CGRequestScreenCaptureAccess() {
            statusMessage = "Allow Screen Recording in the prompt (or Privacy settings), then relaunch"
        }
        refreshPermissions()
    }

    /// Trigger the Accessibility system prompt (needed for the ⌃⌥+brightness keys).
    func requestAccessibilityPermission() {
        _ = BrightnessHotKey.accessibilityTrusted(prompt: true) // shows the allow/deny dialog
        statusMessage = "Allow Accessibility in the prompt, then relaunch for ⌃⌥+brightness"
        refreshPermissions()
    }

    /// Physical displays we deliberately mirror onto a virtual screen — excluded from the
    /// "a display is mirroring" warning, which is only about the glasses arriving mirrored.
    private var intentionalMirrors: Set<CGDirectDisplayID> = []

    func refreshMirroringState() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        mirroringActive = ids.prefix(Int(count)).contains {
            CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay && !intentionalMirrors.contains($0)
        }
    }

    // MARK: Virtual → physical mirroring

    /// Physical displays a virtual screen can be mirrored onto (excludes glasses + virtuals).
    func mirrorTargets() -> [(uuid: String, name: String)] {
        let virtualIDs = Set(virtualDisplays.active.values.map { $0.displayID })
        return NSScreen.screens.compactMap { screen in
            let id = Self.screenDisplayID(screen)
            guard id != glassesDisplayID, !virtualIDs.contains(id),
                  let uuid = Self.displayUUIDString(id) else { return nil }
            return (uuid, screen.localizedName)
        }
    }

    /// Persist the mirror choice on the screen config and apply it live if AR is running.
    func setMirrorTarget(screenID: UUID, physicalUUID: String?) {
        guard var ws = workspaceStore.activeWorkspace,
              let i = ws.virtualScreens.firstIndex(where: { $0.id == screenID }) else { return }
        ws.virtualScreens[i].mirrorToPhysical = physicalUUID
        workspaceStore.activeWorkspace = ws
        workspaceStore.save()
        objectWillChange.send()
        applyMirror(for: ws.virtualScreens[i])
    }

    /// All currently-online display IDs (mirror slaves included — these collapse into a
    /// single NSScreen, so NSScreen.screens can't be used to find/break mirrors).
    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Make the configured physical display mirror this virtual screen (or clear it).
    private func applyMirror(for config: VirtualScreenConfig) {
        guard arActive, let vid = virtualDisplays.displayID(for: config.id) else { return }
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let configRef else { return }
        // Clear any display currently mirroring this virtual one (iterate real display IDs).
        for id in Self.onlineDisplayIDs() where CGDisplayMirrorsDisplay(id) == vid {
            CGConfigureDisplayMirrorOfDisplay(configRef, id, kCGNullDirectDisplay)
            intentionalMirrors.remove(id)
        }
        if let uuid = config.mirrorToPhysical,
           let physicalID = Self.resolvePhysicalDisplay(uuidString: uuid),
           physicalID != glassesDisplayID {
            CGConfigureDisplayMirrorOfDisplay(configRef, physicalID, vid)
            intentionalMirrors.insert(physicalID)
        }
        CGCompleteDisplayConfiguration(configRef, .permanently)
        refreshMirroringState()
    }

    /// Reconcile mirroring at session start: macOS persists and auto-restores mirrors for
    /// our (stable-identity) virtual displays, so first break *every* mirror onto a virtual
    /// display, then apply only the ones the workspace says should be on.
    private func applyConfiguredMirrors() {
        let virtualIDs = Set(virtualDisplays.active.values.map { $0.displayID })
        guard !virtualIDs.isEmpty else { return }

        var configRef: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&configRef) == .success, let configRef {
            var changed = false
            for id in Self.onlineDisplayIDs() where virtualIDs.contains(CGDisplayMirrorsDisplay(id)) {
                CGConfigureDisplayMirrorOfDisplay(configRef, id, kCGNullDirectDisplay)
                intentionalMirrors.remove(id)
                changed = true
            }
            if changed { CGCompleteDisplayConfiguration(configRef, .permanently) }
            else { CGCancelDisplayConfiguration(configRef) }
        }

        if let ws = workspaceStore.activeWorkspace {
            for config in ws.virtualScreens where config.mirrorToPhysical != nil {
                applyMirror(for: config)
            }
        }
        refreshMirroringState()
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

    /// The display AR is currently rendering to (the glasses), if a session is active.
    var arOutputDisplayID: CGDirectDisplayID? { arActive ? glassesDisplayID : nil }

    private func updateCursorConfinement() {
        if arActive, confineCursor, glassesDisplayID != 0 {
            cursorConfiner.start(arDisplayID: glassesDisplayID)
        } else {
            cursorConfiner.stop()
        }
    }

    /// Pick the screen whose centre is closest to the head's forward direction.
    private func updateLookedAtScreen() {
        guard arActive, let ws = workspaceStore.activeWorkspace else {
            if lookedAtScreenID != nil { lookedAtScreenID = nil; lookedAtScreenName = nil }
            return
        }
        let head = IMUService.shared.poseStore.latest().orientation
        let worldForward = simd_normalize(head.act(SIMD3<Float>(0, 0, -1)))
        let viewForward = SIMD3<Float>(0, 0, -1) // floating screens live in view space

        let screens = ws.virtualScreens.filter { $0.showInAR } + ws.physicalInAR.values.filter { $0.showInAR }
        var bestID: UUID?
        var bestName: String?
        var bestDot: Float = -1
        for s in screens {
            let qYaw = simd_quatf(angle: Float(s.yawDegrees * .pi / 180), axis: SIMD3(0, 1, 0))
            let qPitch = simd_quatf(angle: Float(s.pitchDegrees * .pi / 180), axis: SIMD3(1, 0, 0))
            let dir = simd_normalize((qYaw * qPitch).act(SIMD3<Float>(0, 0, -1)))
            // Floating screens are fixed in view space; compare to the view forward instead.
            let d = simd_dot(s.placement == .floating ? viewForward : worldForward, dir)
            if d > bestDot { bestDot = d; bestID = s.id; bestName = s.name }
        }
        // Only count it as "looking at" within ~30° of the screen centre.
        if bestDot < cosf(30 * .pi / 180) { bestID = nil; bestName = nil }
        if bestID != lookedAtScreenID { lookedAtScreenID = bestID; lookedAtScreenName = bestName }
    }

    /// The display that looks like the XREAL glasses, if currently connected.
    func glassesScreenID() -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            let name = screen.localizedName.lowercased()
            if name.contains("air") || name.contains("xreal") || name.contains("nreal") {
                return Self.screenDisplayID(screen)
            }
        }
        return nil
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
        lastOutputScreenID = outputDisplayID
        DebugLog.shared.log("beginAR on '\(screen.localizedName)' id=\(outputDisplayID) frame=\(NSStringFromRect(screen.frame))")

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
        // Keep macOS from throttling our scheduling while head-tracking (App Nap / timer
        // coalescing causes the irregular ~50ms render-delivery stalls).
        if arActivity == nil {
            arActivity = ProcessInfo.processInfo.beginActivity(
                options: [.latencyCritical, .userInitiated, .idleSystemSleepDisabled],
                reason: "AR head-tracked rendering")
        }
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
            self.applyConfiguredMirrors() // restore any virtual→physical mirrors
            self.updateCursorConfinement()
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
        var distance = Float(config.distanceMeters)
        var scale = Float(config.scale)
        var autoCurve = config.autoCurveH
        var cylindrical = false
        // Wide curved canvas: anchored screens share one distance + scale and sit on one
        // shared cylinder centred on the eye, each at its picked yaw AND pitch — so they keep
        // the Layout positioning (side-by-side and above/below) but read as one continuous
        // curved surface instead of separate panels. Shared distance/scale come from the first
        // anchored screen (tune it by adjusting that screen). Mono only.
        if wideCanvas, !stereoEnabled, config.placement != .floating,
           let ref = workspaceStore.activeWorkspace?.virtualScreens
               .first(where: { $0.showInAR && $0.placement != .floating }) {
            distance = Float(ref.distanceMeters)
            scale = Float(ref.scale)
            autoCurve = true
            cylindrical = true
        }
        // Apparent width: ~1.6m per 1920px at scale 1, 2m away.
        let baseWidth = Float(config.width) / 1920.0 * 1.6 * scale
        return SceneScreen(
            id: config.id,
            yaw: Float(config.yawDegrees * .pi / 180),
            pitch: Float(config.pitchDegrees * .pi / 180),
            distance: distance,
            widthMeters: baseWidth,
            aspect: Float(config.width) / Float(config.height),
            curveH: Float(config.curvatureRadius),
            autoCurveH: autoCurve,
            headLocked: config.placement == .floating,
            cylindrical: cylindrical,
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

    static func displayUUIDString(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // MARK: Workspace editing

    func selectWorkspace(_ id: UUID?) {
        guard id != workspaceStore.activeWorkspaceID else { return }
        workspaceStore.activeWorkspaceID = id
        workspaceStore.save()
        objectWillChange.send()
        restartARIfActive()
    }

    func addWorkspace() {
        let ws = Workspace(name: "Workspace \(workspaceStore.workspaces.count + 1)")
        workspaceStore.append(ws)
        workspaceStore.activeWorkspaceID = ws.id
        workspaceStore.save()
        objectWillChange.send()
        restartARIfActive()
    }

    func renameActiveWorkspace(_ name: String) {
        guard var ws = workspaceStore.activeWorkspace else { return }
        ws.name = name
        workspaceStore.activeWorkspace = ws
        workspaceStore.save()
        objectWillChange.send()
    }

    func deleteActiveWorkspace() {
        guard workspaceStore.workspaces.count > 1,
              let id = workspaceStore.activeWorkspaceID else { return }
        workspaceStore.remove(id: id)
        workspaceStore.activeWorkspaceID = workspaceStore.workspaces.first?.id
        workspaceStore.save()
        objectWillChange.send()
        restartARIfActive()
    }

    /// Set while we deliberately change the glasses' display mode (e.g. enabling SBS), so a
    /// transient disconnect during renegotiation isn't mistaken for an unplug.
    var switchingDisplayMode = false

    /// If the glasses display vanishes while AR is running (unplugged), tear down cleanly.
    /// Debounced + mode-switch-aware: a momentary drop during SBS renegotiation or a glitch
    /// shouldn't kill the session, only a display that's still gone a moment later.
    private func handleScreenChange() {
        guard arActive, glassesDisplayID != 0, !switchingDisplayMode else { return }
        guard !NSScreen.screens.contains(where: { Self.screenDisplayID($0) == glassesDisplayID }) else { return }
        let missingID = glassesDisplayID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.arActive, self.glassesDisplayID == missingID, !self.switchingDisplayMode else { return }
            if !NSScreen.screens.contains(where: { Self.screenDisplayID($0) == missingID }) {
                DebugLog.shared.log("Output display \(missingID) gone — stopping AR")
                self.stopAR()
                self.statusMessage = "Glasses disconnected — AR stopped"
            }
        }
    }

    /// After the Mac wakes, capture streams and the output window are usually dead.
    /// Rebuild the session on the same display if it's still there.
    private func handleSystemWake() {
        guard arActive else { return }
        DebugLog.shared.log("System woke — restarting AR")
        statusMessage = "Woke from sleep — restarting AR…"
        restartARIfActive()
    }

    /// Restart AR on the same output so a workspace change rebuilds its virtual displays.
    private func restartARIfActive() {
        guard arActive, lastOutputScreenID != 0 else { return }
        let id = lastOutputScreenID
        stopAR()
        // The display can take a few seconds to re-enumerate (after wake/replug); retry.
        retryStartAR(displayID: id, attemptsLeft: 6)
    }

    private func retryStartAR(displayID id: CGDirectDisplayID, attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.arActive else { return }
            if let screen = NSScreen.screens.first(where: { Self.screenDisplayID($0) == id }) {
                self.startAR(on: screen)
            } else if attemptsLeft > 1 {
                self.retryStartAR(displayID: id, attemptsLeft: attemptsLeft - 1)
            } else {
                self.statusMessage = "Output display didn't return — pick it and Start AR again"
            }
        }
    }

    // MARK: Screen editing (live add / remove)

    func addVirtualScreen(_ config: VirtualScreenConfig) {
        guard var ws = workspaceStore.activeWorkspace else { return }
        ws.virtualScreens.append(config)
        workspaceStore.activeWorkspace = ws
        workspaceStore.save()
        objectWillChange.send()
        guard arActive, config.showInAR,
              let displayID = virtualDisplays.create(config) ?? nil,
              displayID != glassesDisplayID else { return }
        _ = makeSceneScreen(config: config, captureDisplayID: displayID)
        liveUpdateScreens()
    }

    /// Physical displays available to add as AR panels (excludes the glasses output,
    /// our own virtual displays, and ones already added).
    func availablePhysicalDisplays() -> [(uuid: String, name: String)] {
        let virtualIDs = Set(virtualDisplays.active.values.map { $0.displayID })
        let alreadyAdded = Set(workspaceStore.activeWorkspace?.physicalInAR.keys ?? [:].keys)
        var result: [(String, String)] = []
        for screen in NSScreen.screens {
            let id = Self.screenDisplayID(screen)
            guard id != glassesDisplayID, !virtualIDs.contains(id),
                  let uuid = Self.displayUUIDString(id), !alreadyAdded.contains(uuid) else { continue }
            result.append((uuid, screen.localizedName))
        }
        return result
    }

    func addPhysicalScreen(uuidString: String, name: String) {
        guard var ws = workspaceStore.activeWorkspace else { return }
        let displayID = Self.resolvePhysicalDisplay(uuidString: uuidString)
        let size = displayID.flatMap { id in NSScreen.screens.first { Self.screenDisplayID($0) == id } }?.frame.size
        let config = VirtualScreenConfig(
            name: name,
            width: Int(size?.width ?? 1920),
            height: Int(size?.height ?? 1080))
        ws.physicalInAR[uuidString] = config
        workspaceStore.activeWorkspace = ws
        workspaceStore.save()
        objectWillChange.send()
        guard arActive, let displayID, displayID != glassesDisplayID else { return }
        _ = makeSceneScreen(config: config, captureDisplayID: displayID)
        liveUpdateScreens()
    }

    func removeScreen(id: UUID) {
        guard var ws = workspaceStore.activeWorkspace else { return }
        if let idx = ws.virtualScreens.firstIndex(where: { $0.id == id }) {
            ws.virtualScreens.remove(at: idx)
        } else if let key = ws.physicalInAR.first(where: { $0.value.id == id })?.key {
            ws.physicalInAR.removeValue(forKey: key)
        } else {
            return
        }
        workspaceStore.activeWorkspace = ws
        workspaceStore.save()
        objectWillChange.send()
        if let capture = captures[id] {
            captures.removeValue(forKey: id)
            Task { await capture.stop() }
        }
        virtualDisplays.destroy(id) // no-op if it was a physical screen
        liveUpdateScreens()
    }

    /// All editable screens in the active workspace (virtual + physical), for the UI list.
    func editableScreens() -> [VirtualScreenConfig] {
        guard let ws = workspaceStore.activeWorkspace else { return [] }
        return ws.virtualScreens + ws.physicalInAR.values.sorted { $0.name < $1.name }
    }

    func bindingForScreen(id: UUID) -> VirtualScreenConfig? {
        guard let ws = workspaceStore.activeWorkspace else { return nil }
        return ws.virtualScreens.first { $0.id == id }
            ?? ws.physicalInAR.values.first { $0.id == id }
    }

    func updateScreen(_ config: VirtualScreenConfig) {
        guard var ws = workspaceStore.activeWorkspace else { return }
        if let i = ws.virtualScreens.firstIndex(where: { $0.id == config.id }) {
            ws.virtualScreens[i] = config
        } else if let key = ws.physicalInAR.first(where: { $0.value.id == config.id })?.key {
            ws.physicalInAR[key] = config
        } else {
            return
        }
        workspaceStore.activeWorkspace = ws
        workspaceStore.save()
        liveUpdateScreens()
    }

    func stopAR() {
        guard arActive else { return }
        DebugLog.shared.log("stopAR")
        if let arActivity { ProcessInfo.processInfo.endActivity(arActivity); self.arActivity = nil }
        let wasStereo = stereoEnabled
        cursorConfiner.stop()
        // Tear the display link down BEFORE reverting the SBS display mode (reconfiguring a
        // display under a live CAMetalDisplayLink crashes QuartzCore).
        renderer?.stopOutput()
        if wasStereo {
            renderer?.stereoEnabled = false
            stereoEnabled = false
            if glassesDisplayID != 0 {
                DisplayModeSwitcher.switchTo(displayID: glassesDisplayID, width: 1920, height: 1080)
            }
            MCUService.shared.setDisplayMode(.mono1080p60)
        }
        renderer?.setScreens([])
        let activeCaptures = captures.values
        captures.removeAll()
        Task { for c in activeCaptures { await c.stop() } }
        virtualDisplays.destroyAll() // destroying virtual displays auto-breaks their mirrors
        intentionalMirrors.removeAll()
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

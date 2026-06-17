import AppKit
import CapturePipeline
import Compositor
import CoreGraphics
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
    /// Freeze yaw while the head is still to cancel heading drift (default on).
    @Published var driftCorrection: Bool = UserDefaults.standard.object(forKey: "driftCorrection") == nil
        ? true : UserDefaults.standard.bool(forKey: "driftCorrection") {
        didSet { IMUService.shared.driftCorrectionEnabled = driftCorrection
                 UserDefaults.standard.set(driftCorrection, forKey: "driftCorrection") }
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
    private let windowLayout = WindowLayoutStore()
    private let windowRestorePrompt = WindowRestorePromptController()

    /// What to do with a saved window layout when AR starts (ask / always / never).
    @Published var windowRestoreMode: WindowRestoreMode =
        WindowRestoreMode(rawValue: UserDefaults.standard.string(forKey: "windowRestoreMode") ?? "") ?? .ask {
        didSet { UserDefaults.standard.set(windowRestoreMode.rawValue, forKey: "windowRestoreMode") }
    }
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

    /// Wide-canvas-only shared placement controls. Distance affects the composed anchored
    /// canvas as a whole; scale acts as a post-stitch multiplier on the merged canvas.
    @Published var wideCanvasDistanceMeters: Double = UserDefaults.standard.object(forKey: "wideCanvasDistanceMeters") == nil
        ? 2.0 : UserDefaults.standard.double(forKey: "wideCanvasDistanceMeters") {
        didSet {
            UserDefaults.standard.set(wideCanvasDistanceMeters, forKey: "wideCanvasDistanceMeters")
            liveUpdateScreens()
        }
    }
    @Published var wideCanvasScale: Double = UserDefaults.standard.object(forKey: "wideCanvasScale") == nil
        ? 1.0 : UserDefaults.standard.double(forKey: "wideCanvasScale") {
        didSet {
            UserDefaults.standard.set(wideCanvasScale, forKey: "wideCanvasScale")
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

    /// Periodically log system load (load avg, thermal, top CPU procs incl. Sophos) to correlate
    /// render stalls with machine load. Samples off-main every ~3s. Writes to the debug log.
    @Published var systemLoadLogging: Bool = UserDefaults.standard.bool(forKey: "systemLoadLogging") {
        didSet {
            UserDefaults.standard.set(systemLoadLogging, forKey: "systemLoadLogging")
            if systemLoadLogging { DebugLog.shared.setEnabled(true) }
            updateSystemLoadTimer()
        }
    }
    private var systemLoadTimer: Timer?

    private func updateSystemLoadTimer() {
        systemLoadTimer?.invalidate()
        systemLoadTimer = nil
        guard systemLoadLogging else { return }
        DebugLog.shared.log("=== system-load logging on ===")
        systemLoadTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async {
                DebugLog.shared.log("sysload \(SystemLoad.sample())")
            }
        }
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
    /// Last time we persisted the window layout while AR runs (every ~10s), so positions survive
    /// a quit/crash without an explicit Stop.
    private var lastWindowSnapshot: TimeInterval = 0
    private var lastPermissionCheck: TimeInterval = 0
    /// Cache of display localized names keyed by display ID. NSScreen.localizedName does an
    /// IOKit/CoreDisplay lookup (tens of ms) — too expensive to call every 0.5s stats tick on
    /// the main thread, where it starves the render display link. Invalidated on screen changes.
    private var screenNameCache: [CGDirectDisplayID: String] = [:]

    /// The screen the user is currently looking at (gaze nearest its centre), if any.
    @Published var lookedAtScreenID: UUID?
    @Published var lookedAtScreenName: String?

    init() {
        if UserDefaults.standard.bool(forKey: "debugLogging") { DebugLog.shared.setEnabled(true) }
        DebugLog.shared.log("App launched — build \(BuildInfo.version)")
        renderer = GlassesRenderer(poseStore: IMUService.shared.poseStore)
        renderer?.useDedicatedRenderThread = useDedicatedRenderThread
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
        IMUService.shared.driftCorrectionEnabled = driftCorrection

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
                self?.screenNameCache.removeAll() // display set changed — names may differ
                self?.refreshMirroringState()
                self?.syncPhysicalMonitors() // pick up newly connected monitors for the layout
                self?.handleScreenChange()
            }
        }

        // Capture a fresh window-layout snapshot just before sleep, while everything is still on
        // its display — so the post-wake restore has accurate positions to put windows back to.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.arActive else { return }
                self.snapshotWindowLayout()
                DebugLog.shared.log("Will sleep — snapshotted window layout")
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
        updateSystemLoadTimer() // resume if the toggle was persisted on
        // Populate the layout with the currently-connected monitors (positioning-only/green).
        syncPhysicalMonitors()
    }

    /// Localized name for a display, cached (see `screenNameCache`) — only hits the expensive
    /// IOKit lookup on a cache miss, so the 0.5s stats tick stays cheap on the main thread.
    private func cachedScreenName(displayID: CGDirectDisplayID, screen: NSScreen?) -> String {
        if displayID != 0, let cached = screenNameCache[displayID] { return cached }
        let name = screen?.localizedName ?? "Display \(displayID)"
        if displayID != 0 { screenNameCache[displayID] = name }
        return name
    }

    private func updateStats() {
        let now = CACurrentMediaTime()
        let count = IMUService.shared.poseStore.sampleCount
        let rate = Double(count &- lastSampleCount) * 2
        lastSampleCount = count
        let fps = renderer?.framesPerSecond ?? 0

        let q = IMUService.shared.poseStore.latest().orientation
        let toDeg = 180.0 / Double.pi
        let e = (
            yaw: Double(atan2f(2 * (q.real * q.imag.y + q.imag.x * q.imag.z),
                               1 - 2 * (q.imag.y * q.imag.y + q.imag.x * q.imag.x))) * toDeg,
            pitch: Double(asinf(max(-1, min(1, 2 * (q.real * q.imag.x - q.imag.y * q.imag.z))))) * toDeg,
            roll: Double(atan2f(2 * (q.real * q.imag.z + q.imag.x * q.imag.y),
                                1 - 2 * (q.imag.x * q.imag.x + q.imag.z * q.imag.z))) * toDeg
        )

        // Keep the saved window layout fresh while AR runs (every ~10s).
        if arActive, now - lastWindowSnapshot >= 10.0 {
            lastWindowSnapshot = now
            snapshotWindowLayout()
        }

        // Perf snapshot for diagnostics (reads locals, no @Published needed).
        if debugLogging, now - lastLogSnapshot >= 2.0 {
            lastLogSnapshot = now
            let arState = arActive ? "on" : "off"
            let stereoState = stereoEnabled ? "on" : "off"
            let look = lookedAtScreenName ?? "-"
            let disp = renderer?.displayRefreshHz ?? 0
            let path = renderer?.presentPath ?? "—"
            DebugLog.shared.log(String(
                format: "snapshot imu=%.0fHz fps=%.0f disp=%.0fHz present=%@ yaw=%+.1f pitch=%+.1f roll=%+.1f ar=%@ stereo=%@ look=%@",
                rate, fps, disp, path, e.yaw, e.pitch, e.roll, arState, stereoState, look))
        }

        // CRITICAL: while AR is active, do NOT write the live @Published UI readouts below. Each
        // write re-evaluates the entire Control Panel (a persistent NSHostingView) on the main
        // thread — ~45ms — which starves the render display link and produces the ~2Hz head-
        // tracking judder. The panel is behind the glasses during AR; it resumes when AR stops.
        guard !arActive else { return }

        imuRate = rate
        renderFPS = fps
        euler = e

        if let info = renderer?.outputWindowInfo {
            let name = info.displayID != 0 ? cachedScreenName(displayID: info.displayID, screen: nil) : "none"
            outputWindowInfo = "window \(Int(info.frame.width))×\(Int(info.frame.height)) at (\(Int(info.frame.origin.x)),\(Int(info.frame.origin.y))) on \(name)"
        } else {
            outputWindowInfo = "—"
        }
        screenList = NSScreen.screens.map { screen in
            let name = cachedScreenName(displayID: Self.screenDisplayID(screen), screen: screen)
            return "\(name): \(Int(screen.frame.width))×\(Int(screen.frame.height)) at (\(Int(screen.frame.origin.x)),\(Int(screen.frame.origin.y))) scale \(screen.backingScaleFactor)"
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

        // Permissions almost never change at runtime; the check is an expensive off-main
        // round-trip, so refresh at most every ~5s (and only here, outside AR).
        if now - lastPermissionCheck >= 5.0 {
            lastPermissionCheck = now
            refreshPermissions()
        }
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
    /// Display id order from the last OS-arrangement sync, to skip re-applying when unchanged.
    private var lastArrangementSignature: [CGDirectDisplayID] = []
    /// Atlas mapping from the last wide-canvas build, used to place debug marker crosshairs.
    private var lastCanvasMapping: (aMin: Double, bMin: Double, pxH: Double, pxV: Double, w: Int, h: Int)?
    /// The user's OS display origins captured at AR start, restored on Stop so arranging the
    /// desktops to match the GUI doesn't permanently rearrange their physical setup.
    private var savedDisplayOrigins: [CGDirectDisplayID: CGPoint] = [:]

    var sbsModeAvailable: Bool {
        glassesDisplayID != 0 &&
        DisplayModeSwitcher.hasMode(displayID: glassesDisplayID, width: 3840, height: 1080)
    }

    /// Chosen glasses output refresh rate in Hz; 0 = Auto (the display's native max). Persisted.
    /// Defaults to 90: a sustainable rate under load (11.1ms budget vs 8.3ms at 120) so fewer
    /// frames miss their deadline, and the target the reprojection present loop is built around.
    @Published var glassesRefreshRate: Double =
        UserDefaults.standard.object(forKey: "glassesRefreshRate") as? Double ?? 90

    /// Render on a dedicated high-QoS thread (vs the main run loop) so rendering keeps scheduler
    /// priority over background processes on a busy machine. Persisted; rebuilds output on change.
    @Published var useDedicatedRenderThread: Bool =
        UserDefaults.standard.object(forKey: "useDedicatedRenderThread") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useDedicatedRenderThread, forKey: "useDedicatedRenderThread")
            renderer?.useDedicatedRenderThread = useDedicatedRenderThread
            rebuildOutputIfActive()
        }
    }

    /// Tear down and rebuild the glasses output so a renderer flag change takes effect mid-AR.
    private func rebuildOutputIfActive() {
        guard arActive, let renderer else { return }
        switchingDisplayMode = true
        renderer.stopOutput()
        restartOutputOnGlasses(after: 0.4)
    }

    /// Glasses display id, resolving via the connected screen if AR hasn't set it yet.
    private var resolvedGlassesDisplayID: CGDirectDisplayID {
        glassesDisplayID != 0 ? glassesDisplayID : (glassesScreenID() ?? 0)
    }

    /// Refresh rates the glasses advertise at 1920×1080 (descending) — for the picker.
    func availableGlassesRefreshRates() -> [Double] {
        let id = resolvedGlassesDisplayID
        guard id != 0 else { return [] }
        return DisplayModeSwitcher.availableRefreshRates(id, width: 1920, height: 1080)
    }

    /// Set the glasses output refresh rate. Switches the *actual* macOS display mode so the panel
    /// genuinely runs at that rate (the render link then paces to it). 0 = Auto (native max). When
    /// AR is live the display link is torn down before the switch (a live link across a mode change
    /// crashes QuartzCore) and rebuilt after.
    func setGlassesRefreshRate(_ rate: Double) {
        glassesRefreshRate = rate
        UserDefaults.standard.set(rate, forKey: "glassesRefreshRate")
        let id = resolvedGlassesDisplayID
        guard id != 0 else { return }
        let target = rate > 0 ? rate : (availableGlassesRefreshRates().first ?? 120)
        let arState = arActive
        DebugLog.shared.log("setGlassesRefreshRate ask=\(rate) target=\(target)Hz id=\(id) ar=\(arState)")
        if arActive, let renderer {
            switchingDisplayMode = true
            renderer.stopOutput()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                DisplayModeSwitcher.switchTo(displayID: id, width: 1920, height: 1080, refresh: target)
                self.restartOutputOnGlasses(after: 0.6)
            }
        } else {
            DisplayModeSwitcher.switchTo(displayID: id, width: 1920, height: 1080, refresh: target)
        }
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

    /// Refresh cached permission flags off the main thread. CGPreflightScreenCaptureAccess does
    /// synchronous XPC (tens of ms) — calling it inline on the 0.5s stats tick starved the render
    /// display link. Runs the checks on a background queue and publishes the results back.
    func refreshPermissions() {
        DispatchQueue.global(qos: .utility).async {
            let screen = CGPreflightScreenCaptureAccess()
            let ax = BrightnessHotKey.accessibilityTrusted(prompt: false)
            Task { @MainActor [weak self] in
                self?.hasScreenRecordingPermission = screen
                self?.hasAccessibilityPermission = ax
            }
        }
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

    // MARK: Virtual → virtual mirroring (AR-only: a screen shows another screen's content)

    /// The capture a screen should render: its mirror source's capture if it mirrors another
    /// virtual screen, otherwise its own.
    private func captureForConfig(_ config: VirtualScreenConfig) -> CaptureSource? {
        captures[config.mirrorOfVirtual ?? config.id]
    }

    /// Virtual screens `screenID` may mirror: other virtual screens that aren't themselves
    /// mirrors (no chains) and aren't this screen.
    func virtualMirrorTargets(for screenID: UUID) -> [(id: UUID, name: String)] {
        guard let ws = workspaceStore.activeWorkspace else { return [] }
        return ws.virtualScreens
            .filter { $0.id != screenID && $0.mirrorOfVirtual == nil }
            .map { ($0.id, $0.name) }
    }

    /// Set (or clear) which virtual screen this one mirrors. Applies live without a full restart:
    /// turning mirroring on drops the screen's own virtual display; turning it off recreates one.
    func setVirtualMirror(screenID: UUID, sourceID: UUID?) {
        guard var ws = workspaceStore.activeWorkspace,
              let i = ws.virtualScreens.firstIndex(where: { $0.id == screenID }) else { return }
        // Guard against chains: only non-mirror screens are valid sources.
        if let sourceID, ws.virtualScreens.first(where: { $0.id == sourceID })?.mirrorOfVirtual != nil {
            return
        }
        ws.virtualScreens[i].mirrorOfVirtual = sourceID
        if sourceID != nil {
            ws.virtualScreens[i].mirrorToPhysical = nil      // a mirror has no display to mirror out
            // Clear any screens that were mirroring this one — it can no longer be a source.
            for j in ws.virtualScreens.indices where ws.virtualScreens[j].mirrorOfVirtual == screenID {
                ws.virtualScreens[j].mirrorOfVirtual = nil
            }
        }
        workspaceStore.activeWorkspace = ws
        workspaceStore.save()
        objectWillChange.send()

        guard arActive else { return }
        let cfg = ws.virtualScreens[i]
        if sourceID != nil {
            // Became a mirror: tear down its own display + capture.
            if let cap = captures[cfg.id] {
                captures.removeValue(forKey: cfg.id)
                Task { await cap.stop() }
            }
            virtualDisplays.destroy(cfg.id)
        } else if captures[cfg.id] == nil {
            // Became a normal screen: give it back its own display + capture.
            if let displayID = virtualDisplays.create(cfg) ?? nil, displayID != glassesDisplayID {
                _ = makeCapture(config: cfg, captureDisplayID: displayID)
            }
        }
        liveUpdateScreens()
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
        let best = lookedAtConfig()
        let id = best?.id, name = best?.name
        if id != lookedAtScreenID { lookedAtScreenID = id; lookedAtScreenName = name }
    }

    /// The screen config the gaze (head forward) is nearest the centre of, within ~30°.
    /// Shared by the live "looking at" readout and the on-demand gaze-coordinate snapshot.
    private func lookedAtConfig() -> VirtualScreenConfig? {
        guard arActive, let ws = workspaceStore.activeWorkspace else { return nil }
        let head = IMUService.shared.poseStore.latest().orientation
        let worldForward = simd_normalize(head.act(SIMD3<Float>(0, 0, -1)))
        let viewForward = SIMD3<Float>(0, 0, -1) // floating screens live in view space

        let screens = ws.virtualScreens.filter { $0.showInAR } + ws.physicalInAR.values.filter { $0.showInAR }
        var best: VirtualScreenConfig?
        var bestDot: Float = -1
        for s in screens {
            let qYaw = simd_quatf(angle: Float(s.yawDegrees * .pi / 180), axis: SIMD3(0, 1, 0))
            let qPitch = simd_quatf(angle: Float(s.pitchDegrees * .pi / 180), axis: SIMD3(1, 0, 0))
            let dir = simd_normalize((qYaw * qPitch).act(SIMD3<Float>(0, 0, -1)))
            // Floating screens are fixed in view space; compare to the view forward instead.
            let d = simd_dot(s.placement == .floating ? viewForward : worldForward, dir)
            if d > bestDot { bestDot = d; best = s }
        }
        // Only count it as "looking at" within ~30° of the screen centre.
        return bestDot < cosf(30 * .pi / 180) ? nil : best
    }

    /// Where on the looked-at screen the gaze lands, computed on demand (e.g. when the cursor-info
    /// popup opens). Intentionally NOT a live @Published value — writing one every IMU tick would
    /// re-render the Control Panel each frame and bring back the head-tracking judder. The hit is
    /// the head-forward ray (no eye tracking) intersected with the screen's surface, in pixels.
    func currentGaze() -> GazeReadout? {
        guard let s = lookedAtConfig() else { return nil }
        let gaze: SIMD3<Float>
        if s.placement == .floating {
            gaze = SIMD3<Float>(0, 0, -1)
        } else {
            let head = IMUService.shared.poseStore.latest().orientation
            gaze = simd_normalize(head.act(SIMD3<Float>(0, 0, -1)))
        }
        // Rotate the gaze into the screen's local frame (undo its yaw/pitch placement).
        let qYaw = simd_quatf(angle: Float(s.yawDegrees * .pi / 180), axis: SIMD3(0, 1, 0))
        let qPitch = simd_quatf(angle: Float(s.pitchDegrees * .pi / 180), axis: SIMD3(1, 0, 0))
        let localDir = simd_normalize((qYaw * qPitch).inverse.act(gaze))
        guard localDir.z < -1e-4 else { return nil } // gaze pointing away from the surface

        // Geometry must match sceneScreen(config:capture:): ~1.6m per 1920px at scale 1.
        let widthMeters = Float(s.width) / 1920.0 * 1.6 * Float(s.scale)
        let aspect = Float(s.width) / Float(max(1, s.height))
        let heightMeters = widthMeters / max(0.0001, aspect)
        let distance = Float(s.distanceMeters)

        // Horizontal: angular mapping when curved (matches the mesh's arc), exact flat-plane
        // intersection otherwise. Vertical surface is always flat, so intersect the z=-distance plane.
        let arcPerUnit: Float = 30 * .pi / 180
        let thetaX = (s.autoCurveH ? widthMeters / distance : Float(s.curvatureRadius) * arcPerUnit)
        let azimuth = atan2(localDir.x, -localDir.z)
        let u: Float = thetaX > 0.001 ? (0.5 + azimuth / thetaX)
                                      : (0.5 + distance * tanf(azimuth) / widthMeters)
        let t = distance / (-localDir.z)
        let v = 0.5 - (localDir.y * t) / heightMeters

        let offScreen = u < 0 || u > 1 || v < 0 || v > 1
        let px = CGFloat(min(1, max(0, u))) * CGFloat(s.width)
        let py = CGFloat(min(1, max(0, v))) * CGFloat(s.height)
        return GazeReadout(screenName: s.name,
                           displayID: displayID(forConfig: s),
                           pixel: CGPoint(x: px.rounded(), y: py.rounded()),
                           screenSize: CGSize(width: s.width, height: s.height),
                           offScreen: offScreen)
    }

    /// The macOS display ID a screen config currently maps to (virtual or physical), or 0.
    private func displayID(forConfig s: VirtualScreenConfig) -> CGDirectDisplayID {
        if let d = virtualDisplays.displayID(for: s.id) { return d }
        if let entry = workspaceStore.activeWorkspace?.physicalInAR.first(where: { $0.value.id == s.id }) {
            return Self.resolvePhysicalDisplay(uuidString: entry.key) ?? 0
        }
        return 0
    }

    /// Direction from the eye to the mouse cursor in AR space, relative to where the head is
    /// pointing now (so a popup arrow can show which way to turn to find the cursor). `u`/`v` are
    /// the cursor's fractional position on its display (top-left origin). On-demand, like the gaze
    /// readout — no live @Published writes. Returns nil if AR is off or the cursor isn't on an AR
    /// screen.
    func cursorDirection(onDisplayID displayID: CGDirectDisplayID, u: Double, v: Double) -> CursorDirection? {
        guard arActive, displayID != 0, let ws = workspaceStore.activeWorkspace else { return nil }

        // Map the display under the cursor to its AR screen config.
        var config: VirtualScreenConfig?
        if let entry = virtualDisplays.active.first(where: { $0.value.displayID == displayID }) {
            config = ws.virtualScreens.first { $0.id == entry.key }
        }
        if config == nil {
            for (uuid, cfg) in ws.physicalInAR where cfg.showInAR {
                if Self.resolvePhysicalDisplay(uuidString: uuid) == displayID { config = cfg; break }
            }
        }
        guard let s = config else { return nil }

        // Cursor's 3D position on that screen — the inverse of currentGaze()'s pixel mapping.
        let widthMeters = Float(s.width) / 1920.0 * 1.6 * Float(s.scale)
        let aspect = Float(s.width) / Float(max(1, s.height))
        let heightMeters = widthMeters / max(0.0001, aspect)
        let distance = Float(s.distanceMeters)
        let arcPerUnit: Float = 30 * .pi / 180
        let thetaX = (s.autoCurveH ? widthMeters / distance : Float(s.curvatureRadius) * arcPerUnit)
        let uu = Float(u), vv = Float(v)
        var localX: Float
        var zDev: Float = 0
        if thetaX > 0.001 {
            let ax = (uu - 0.5) * thetaX
            let rX = widthMeters / thetaX
            localX = sinf(ax) * rX
            zDev = rX * (1 - cosf(ax))
        } else {
            localX = (uu - 0.5) * widthMeters
        }
        let localY = (0.5 - vv) * heightMeters
        let local = SIMD3<Float>(localX, localY, -distance + zDev)
        let qYaw = simd_quatf(angle: Float(s.yawDegrees * .pi / 180), axis: SIMD3(0, 1, 0))
        let qPitch = simd_quatf(angle: Float(s.pitchDegrees * .pi / 180), axis: SIMD3(1, 0, 0))
        let world = (qYaw * qPitch).act(local)

        // Direction in head/view space (floating screens already live in view space).
        let viewDir: SIMD3<Float>
        if s.placement == .floating {
            viewDir = simd_normalize(world)
        } else {
            let head = IMUService.shared.poseStore.latest().orientation
            viewDir = simd_normalize(head.inverse.act(world))
        }
        let azimuth = atan2(viewDir.x, -viewDir.z)        // + = right
        let elevation = asin(max(-1, min(1, viewDir.y)))  // + = up
        let centered = abs(azimuth) < (2 * .pi / 180) && abs(elevation) < (2 * .pi / 180)
        return CursorDirection(azimuthDeg: Double(azimuth) * 180 / .pi,
                               elevationDeg: Double(elevation) * 180 / .pi,
                               angleRadians: atan2(Double(azimuth), Double(elevation)),
                               centered: centered)
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

        let outputDisplayID = Self.screenDisplayID(screen)
        glassesDisplayID = outputDisplayID
        lastOutputScreenID = outputDisplayID
        // Snapshot the user's current OS display arrangement so we can restore it on Stop —
        // we're about to move real monitors to match the GUI ("move everything").
        snapshotDisplayArrangement()
        // Make sure every connected monitor is in the layout (the main display anchors the OS
        // arrangement). (Re-reads the workspace below in case this adds entries.)
        syncPhysicalMonitors()
        guard let workspace = workspaceStore.activeWorkspace else { return }
        DebugLog.shared.log("beginAR on '\(screen.localizedName)' id=\(outputDisplayID) frame=\(NSStringFromRect(screen.frame))")

        // 1. Create virtual displays for the workspace. Mirror screens get no display of their
        //    own — they reuse their source screen's capture (added after sources exist).
        var pairs: [(config: VirtualScreenConfig, capture: CaptureSource)] = []
        for config in workspace.virtualScreens where config.showInAR && config.mirrorOfVirtual == nil {
            guard let displayID = virtualDisplays.create(config) ?? nil else {
                statusMessage = "CGVirtualDisplay unavailable — \(config.name) skipped"
                continue
            }
            guard displayID != outputDisplayID else { continue } // never capture the glasses display
            pairs.append((config, makeCapture(config: config, captureDisplayID: displayID)))
        }
        for config in workspace.virtualScreens where config.showInAR && config.mirrorOfVirtual != nil {
            if let capture = captureForConfig(config) { pairs.append((config, capture)) }
        }

        // 2. Physical displays mirrored into AR.
        for (uuidString, config) in workspace.physicalInAR where config.showInAR {
            guard let displayID = Self.resolvePhysicalDisplay(uuidString: uuidString),
                  displayID != outputDisplayID else { continue }
            pairs.append((config, makeCapture(config: config, captureDisplayID: displayID)))
        }

        renderer.setScreens(assembleScene(pairs))
        arActive = true
        lastWindowSnapshot = CACurrentMediaTime() // defer the first periodic snapshot ~10s

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
        let screenCount = pairs.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.arActive else { return }
            // Lay the OS displays out to match the GUI before opening the output window.
            self.arrangeDisplaysToMatchGUI(force: true)
            let target = NSScreen.screens.first { Self.screenDisplayID($0) == outputDisplayID } ?? screen
            renderer.startOutput(on: target)
            self.outputScreenName = target.localizedName
            self.applyConfiguredMirrors() // restore any virtual→physical mirrors
            self.updateCursorConfinement()
            self.statusMessage = "AR active on \(target.localizedName) \(Int(target.frame.width))×\(Int(target.frame.height)) at (\(Int(target.frame.origin.x)),\(Int(target.frame.origin.y))) with \(screenCount) screen(s)"
            // Let the OS arrangement settle, then offer to put windows back on their screens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.arActive else { return }
                self.maybeRestoreWindowLayout()
            }
        }
    }

    /// Create and start a capture for a screen, registering it in `captures`.
    private func makeCapture(config: VirtualScreenConfig, captureDisplayID: CGDirectDisplayID) -> CaptureSource {
        let capture = CaptureSource(displayID: captureDisplayID, device: renderer!.device)
        captures[config.id] = capture
        Task {
            do { try await capture.start() }
            catch { await MainActor.run { self.statusMessage = "Capture failed for \(config.name): \(error.localizedDescription)" } }
        }
        return capture
    }

    /// Build the placement geometry for a single screen (its own distance/scale/curve), reusing
    /// an existing capture. Wide-canvas merging is handled separately in `makeCanvasSceneScreen`.
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
            curveH: Float(config.curvatureRadius),
            autoCurveH: config.autoCurveH,
            headLocked: config.placement == .floating,
            textureProvider: { [weak capture] in capture?.latestTexture }
        )
    }

    /// Stable id for the single merged wide-canvas surface (so its atlas/vertex caches persist
    /// across live rebuilds).
    private static let wideCanvasID = UUID(uuidString: "CA9A5000-0000-0000-0000-000000000001")!

    /// Build one merged wide-canvas surface from the anchored screens. Each screen is placed on
    /// a single flat atlas at its **true GUI position** (yaw → horizontal, pitch → vertical) and
    /// its true angular size — reproducing the Layout map exactly — then the whole atlas, cropped
    /// to the screens' bounding box, is wrapped onto one horizontally-curved mesh. The atlas is
    /// sized to the glasses' native density (≈48 px/°) so a FOV-sized patch maps ~1:1. The shared
    /// canvas distance only sets how far the merged surface floats; canvas scale resizes the whole
    /// surface. Both leave the relative layout untouched. Returns nil if no screens.
    private func makeCanvasSceneScreen(_ anchored: [(config: VirtualScreenConfig, capture: CaptureSource)]) -> SceneScreen? {
        guard !anchored.isEmpty else { return nil }

        // FOV-matched density (pixels per degree), matching the renderer's projection: each eye
        // is 1920×1080 over a 23° vertical FOV at 16:9.
        let fovYDeg = 23.0
        let fovXDeg = 2.0 * atan(tan(fovYDeg / 2.0 * .pi / 180.0) * (16.0 / 9.0)) * 180.0 / .pi
        var pxPerDegH = 1920.0 / fovXDeg
        var pxPerDegV = 1080.0 / fovYDeg

        // Per-screen placement on the flat atlas. Atlas axes are screen-space: a = −yaw grows to
        // the right, b = −pitch grows downward (matching the Layout editor's mapping). Size uses
        // each screen's own scale + distance, exactly like the Layout box, so the atlas mirrors
        // the GUI (including any gaps the user left).
        struct Tile { let provider: () -> MTLTexture?
                      let aLeft: Double; let bTop: Double; let wDeg: Double; let hDeg: Double }
        let tiles: [Tile] = anchored.map { (config, capture) in
            let widthMeters = Double(config.width) / 1920.0 * 1.6 * config.scale
            let aspect = Double(config.width) / Double(config.height)
            let heightMeters = widthMeters / aspect
            let dist = max(0.1, config.distanceMeters)
            let wDeg = 2.0 * atan((widthMeters / 2.0) / dist) * 180.0 / .pi
            let hDeg = 2.0 * atan((heightMeters / 2.0) / dist) * 180.0 / .pi
            return Tile(provider: { [weak capture] in capture?.latestTexture },
                        aLeft: -config.yawDegrees - wDeg / 2.0,
                        bTop: -config.pitchDegrees - hDeg / 2.0,
                        wDeg: wDeg, hDeg: hDeg)
        }

        // Bounding box of all screens (degrees), cropping away the surrounding blank space.
        let aMin = tiles.map(\.aLeft).min()!
        let aMax = tiles.map { $0.aLeft + $0.wDeg }.max()!
        let bMin = tiles.map(\.bTop).min()!
        let bMax = tiles.map { $0.bTop + $0.hDeg }.max()!
        let arcWDeg = max(0.001, aMax - aMin)
        let arcHDeg = max(0.001, bMax - bMin)

        // Clamp density so the atlas stays within Metal's 16384px limit.
        let maxDim = max(arcWDeg * pxPerDegH, arcHDeg * pxPerDegV)
        if maxDim > 16384 {
            let k = 16384.0 / maxDim
            pxPerDegH *= k; pxPerDegV *= k
            DebugLog.shared.log("wide canvas: clamped density ×\(String(format: "%.2f", k))")
        }

        let canvasW = max(1, Int((arcWDeg * pxPerDegH).rounded()))
        let canvasH = max(1, Int((arcHDeg * pxPerDegV).rounded()))
        // Remember the atlas mapping so the debug capture can place its marker crosshairs.
        lastCanvasMapping = (aMin: aMin, bMin: bMin, pxH: pxPerDegH, pxV: pxPerDegV, w: canvasW, h: canvasH)
        let canvasTiles: [CanvasTile] = tiles.map { t in
            CanvasTile(sourceProvider: t.provider,
                       destX: Int(((t.aLeft - aMin) * pxPerDegH).rounded()),
                       destY: Int(((t.bTop - bMin) * pxPerDegV).rounded()),
                       destWidth: max(1, Int((t.wDeg * pxPerDegH).rounded())),
                       destHeight: max(1, Int((t.hDeg * pxPerDegV).rounded())))
        }

        // Curve the whole canvas as one surface, positioned at the GUI layout's centre (the
        // middle of the bounding box) — not snapped to straight ahead. Atlas axes are a = −yaw,
        // b = −pitch, so the centre direction is yaw = −centreA, pitch = −centreB. Canvas scale
        // resizes it; the shared distance sets how far it floats.
        let centreA = (aMin + aMax) / 2.0
        let centreB = (bMin + bMax) / 2.0
        let distance = Float(wideCanvasDistanceMeters)
        let arcWRad = arcWDeg * .pi / 180.0
        return SceneScreen(
            canvasID: Self.wideCanvasID,
            yaw: Float(-centreA * .pi / 180.0),
            pitch: Float(-centreB * .pi / 180.0),
            distance: distance,
            widthMeters: Float(arcWRad) * distance * Float(wideCanvasScale),
            aspect: Float(arcWDeg / arcHDeg),
            canvasPixelWidth: canvasW, canvasPixelHeight: canvasH,
            tiles: canvasTiles
        )
    }

    /// Assemble the renderer's scene from (config, capture) pairs. In wide-canvas mono mode the
    /// anchored screens are merged into one curved canvas; floating screens stay separate.
    private func assembleScene(_ pairs: [(config: VirtualScreenConfig, capture: CaptureSource)]) -> [SceneScreen] {
        guard wideCanvas, !stereoEnabled else {
            return pairs.map { sceneScreen(config: $0.config, capture: $0.capture) }
        }
        let anchored = pairs.filter { $0.config.placement != .floating }
        let floating = pairs.filter { $0.config.placement == .floating }
        var result: [SceneScreen] = []
        if let canvas = makeCanvasSceneScreen(anchored) { result.append(canvas) }
        result += floating.map { sceneScreen(config: $0.config, capture: $0.capture) }
        return result
    }

    /// Rebuild the live scene from the active workspace's current placement values,
    /// reusing existing captures so a slider drag updates the AR view in real time.
    /// (Adding/removing screens or toggling "show in AR" still needs a Start/Stop.)
    func liveUpdateScreens() {
        guard let renderer, arActive,
              let workspace = workspaceStore.activeWorkspace else { return }
        var pairs: [(config: VirtualScreenConfig, capture: CaptureSource)] = []
        for config in workspace.virtualScreens where config.showInAR {
            if let capture = captureForConfig(config) { pairs.append((config, capture)) }
        }
        for (_, config) in workspace.physicalInAR where config.showInAR {
            if let capture = captures[config.id] { pairs.append((config, capture)) }
        }
        renderer.setScreens(assembleScene(pairs))
        // Re-sync the OS arrangement if the screens' left→right / row order changed.
        arrangeDisplaysToMatchGUI(force: false)
    }

    // MARK: OS display arrangement

    /// The glasses display id, whether or not AR is running (falls back to the name heuristic
    /// when there's no active session so we never treat the glasses as a desktop monitor).
    private var effectiveGlassesID: CGDirectDisplayID {
        glassesDisplayID != 0 ? glassesDisplayID : (glassesScreenID() ?? 0)
    }

    /// Physical display UUIDs currently used as a mirror target of a virtual screen. These are
    /// represented in the layout by the virtual screen mirrored onto them, so we don't show a
    /// separate box for them (and they're excluded from the OS arrangement).
    private func physicalMirrorTargetUUIDs() -> Set<String> {
        guard let ws = workspaceStore.activeWorkspace else { return [] }
        return Set(ws.virtualScreens.compactMap { $0.mirrorToPhysical })
    }

    /// True if the display behind `uuid` is connected and isn't a virtual display or a mirror
    /// target — i.e. it should appear in the Layout map as a real monitor.
    func isLayoutPhysical(uuid: String) -> Bool {
        guard let id = Self.resolvePhysicalDisplay(uuidString: uuid), id != effectiveGlassesID else { return false }
        let virtualIDs = Set(virtualDisplays.active.values.map { $0.displayID })
        return !virtualIDs.contains(id) && !physicalMirrorTargetUUIDs().contains(uuid)
    }

    /// Ensure every connected physical display (except the glasses output, our own virtual
    /// displays, and mirror targets) has a placement config in the active workspace, so it
    /// appears in the Layout map as a positioning reference. New monitors default to
    /// positioning-only (`showInAR = false`, green) — visible in the GUI and the OS arrangement
    /// but never captured or rendered into the glasses. The Mac's main display anchors the
    /// arrangement. No-op when nothing new is found.
    func syncPhysicalMonitors() {
        guard var ws = workspaceStore.activeWorkspace else { return }
        let glasses = effectiveGlassesID
        let virtualIDs = Set(virtualDisplays.active.values.map { $0.displayID })
        let mirrorTargets = physicalMirrorTargetUUIDs()
        var changed = false
        for screen in NSScreen.screens {
            let id = Self.screenDisplayID(screen)
            guard id != glasses, id != 0, !virtualIDs.contains(id),
                  let uuid = Self.displayUUIDString(id), !mirrorTargets.contains(uuid),
                  ws.physicalInAR[uuid] == nil else { continue }
            let size = screen.frame.size
            ws.physicalInAR[uuid] = VirtualScreenConfig(
                name: screen.localizedName,
                width: Int(size.width), height: Int(size.height),
                showInAR: false) // positioning-only (green) until the user opts it into AR
            changed = true
            DebugLog.shared.log("layout: added physical monitor '\(screen.localizedName)' (positioning-only)")
        }
        if changed {
            workspaceStore.activeWorkspace = ws
            workspaceStore.save()
            objectWillChange.send()
        }
    }

    private struct ArrangedDisplay { let id: CGDirectDisplayID; let w: Int; let h: Int }

    /// Displays grouped into rows as they should tile in the OS arrangement: rows top→bottom by
    /// pitch, left→right by yaw within a row (+yaw is to the left). Excludes the glasses output.
    private func arrangementRows() -> [[ArrangedDisplay]] {
        guard let ws = workspaceStore.activeWorkspace else { return [] }
        struct E { let pitch: Double; let yaw: Double; let d: ArrangedDisplay }
        var entries: [E] = []
        func add(_ cfg: VirtualScreenConfig, _ id: CGDirectDisplayID) {
            guard id != glassesDisplayID else { return }
            let b = CGDisplayBounds(id)
            entries.append(E(pitch: cfg.pitchDegrees, yaw: cfg.yawDegrees,
                             d: ArrangedDisplay(id: id, w: Int(b.width), h: Int(b.height))))
        }
        for cfg in ws.virtualScreens where cfg.showInAR && cfg.placement == .anchored {
            if let id = virtualDisplays.displayID(for: cfg.id) { add(cfg, id) }
        }
        // Physical monitors anchor the layout whether or not they're shown in the glasses:
        // positioning-only (green) monitors still define where the virtual screens sit relative
        // to the main display. Mirror targets are excluded (represented by their virtual screen).
        let mirrorTargets = physicalMirrorTargetUUIDs()
        for (uuid, cfg) in ws.physicalInAR where !mirrorTargets.contains(uuid) {
            if let id = Self.resolvePhysicalDisplay(uuidString: uuid) { add(cfg, id) }
        }
        let rows = Dictionary(grouping: entries) { Int($0.pitch.rounded()) }
        return rows.keys.sorted(by: >).map { key in
            rows[key]!.sorted { $0.yaw > $1.yaw }.map(\.d)
        }
    }

    /// Lay the OS displays out edge-to-edge to match the GUI order, anchored so the Mac's main
    /// display stays at the origin. Parks the glasses output beyond the right edge so it doesn't
    /// overlap. When `force` is false, skips the (heavy, flicker-prone) reconfigure unless the
    /// left→right / row order actually changed since the last sync.
    private func arrangeDisplaysToMatchGUI(force: Bool) {
        guard arActive else { return }
        let rows = arrangementRows()
        let all = rows.flatMap { $0 }
        guard !all.isEmpty else { return }
        let signature = all.map(\.id)
        if !force && signature == lastArrangementSignature { return }

        // Pack edge-to-edge within each row, advancing y between rows. Each row is centred on a
        // shared centre line (x = 0) rather than packed from the left, so rows of different widths
        // stay aligned by their middle — e.g. a centred laptop display sits directly below the
        // middle of a wider AR strip, matching the GUI, instead of flush-left under it.
        var positions: [CGDirectDisplayID: (x: Int, y: Int)] = [:]
        var y = 0
        for row in rows {
            let rowW = row.reduce(0) { $0 + $1.w }
            var x = -rowW / 2, rowH = 0
            for d in row { positions[d.id] = (x, y); x += d.w; rowH = max(rowH, d.h) }
            y += rowH
        }

        // Anchor the arrangement on the Mac's main display (kept at the origin by macOS).
        let origin = positions[CGMainDisplayID()] ?? (x: 0, y: 0)
        var ref: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&ref) == .success, let ref else { return }
        for d in all {
            let p = positions[d.id] ?? (0, 0)
            CGConfigureDisplayOrigin(ref, d.id, Int32(p.x - origin.x), Int32(p.y - origin.y))
        }
        // Park the glasses display just past the right edge so it doesn't overlap the desktops.
        if glassesDisplayID != 0 {
            let rightEdge = (all.map { (positions[$0.id]?.x ?? 0) + $0.w }.max() ?? 0) - origin.x
            CGConfigureDisplayOrigin(ref, glassesDisplayID, Int32(rightEdge), 0)
        }
        if CGCompleteDisplayConfiguration(ref, .forSession) == .success {
            lastArrangementSignature = signature
            DebugLog.shared.log("arrange: applied OS layout for \(all.count) display(s)")
        } else {
            CGCancelDisplayConfiguration(ref)
            DebugLog.shared.log("arrange: CGCompleteDisplayConfiguration failed")
        }
    }

    // MARK: Window layout persistence

    /// Live display id → stable screen key for every screen whose windows we track: virtual
    /// screens shown in AR, plus all connected physical monitors (green or orange). Excludes the
    /// glasses output. Used to snapshot/restore which screen each app window sits on.
    private func trackedDisplays() -> [(id: CGDirectDisplayID, key: String)] {
        guard let ws = workspaceStore.activeWorkspace else { return [] }
        var out: [(CGDirectDisplayID, String)] = []
        for cfg in ws.virtualScreens where cfg.showInAR {
            if let id = virtualDisplays.displayID(for: cfg.id) {
                out.append((id, "v:\(cfg.id.uuidString)"))
            }
        }
        for (uuid, _) in ws.physicalInAR {
            if let id = Self.resolvePhysicalDisplay(uuidString: uuid),
               id != effectiveGlassesID {
                out.append((id, "p:\(uuid)"))
            }
        }
        return out
    }

    /// Turn a stored screen key back into the current display id (nil if absent this session).
    private func resolveScreenKey(_ key: String) -> CGDirectDisplayID? {
        if key.hasPrefix("v:"), let uuid = UUID(uuidString: String(key.dropFirst(2))) {
            return virtualDisplays.displayID(for: uuid)
        } else if key.hasPrefix("p:") {
            return Self.resolvePhysicalDisplay(uuidString: String(key.dropFirst(2)))
        }
        return nil
    }

    /// Record where each app's windows currently sit. Call at the top of `stopAR`, before the
    /// virtual displays are destroyed (which would scatter their windows).
    private func snapshotWindowLayout() {
        guard let id = workspaceStore.activeWorkspaceID else { return }
        windowLayout.snapshot(workspaceID: id, displays: trackedDisplays())
    }

    /// After AR starts and the displays settle, restore the saved window layout per the user's
    /// preference (ask / always / never). Needs Accessibility permission to move other apps' windows.
    private func maybeRestoreWindowLayout() {
        guard let id = workspaceStore.activeWorkspaceID, windowLayout.hasLayout(for: id),
              windowRestoreMode != .never else { return }
        guard hasAccessibilityPermission else {
            statusMessage = "Grant Accessibility to restore window layouts (Permissions)"
            return
        }
        switch windowRestoreMode {
        case .always:
            restoreWindowLayoutNow()
        case .ask:
            windowRestorePrompt.present(count: windowLayout.count(for: id),
                                        excluding: arOutputDisplayID) { [weak self] restore in
                if restore { self?.restoreWindowLayoutNow() }
            }
        case .never:
            break
        }
    }

    private func restoreWindowLayoutNow() {
        guard let id = workspaceStore.activeWorkspaceID else { return }
        let n = windowLayout.restore(workspaceID: id) { [weak self] key in
            self?.resolveScreenKey(key)
        }
        statusMessage = "Restored \(n) window\(n == 1 ? "" : "s") to their screens"
        DebugLog.shared.log("window layout: restored \(n) window(s)")
    }

    /// Record every online display's current global origin, so Stop can put the user's real
    /// desktop arrangement back the way they had it before AR rearranged things.
    private func snapshotDisplayArrangement() {
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        for id in Self.onlineDisplayIDs() {
            origins[id] = CGDisplayBounds(id).origin
        }
        savedDisplayOrigins = origins
    }

    /// Restore the display origins captured at AR start (for displays still connected). Called
    /// on Stop. No-op if nothing was captured.
    private func restoreDisplayArrangement() {
        guard !savedDisplayOrigins.isEmpty else { return }
        let online = Set(Self.onlineDisplayIDs())
        var ref: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&ref) == .success, let ref else { return }
        for (id, origin) in savedDisplayOrigins where online.contains(id) {
            CGConfigureDisplayOrigin(ref, id, Int32(origin.x), Int32(origin.y))
        }
        if CGCompleteDisplayConfiguration(ref, .permanently) == .success {
            DebugLog.shared.log("arrange: restored pre-AR display layout")
        } else {
            CGCancelDisplayConfiguration(ref)
        }
        savedDisplayOrigins = [:]
    }

    /// Debug: write the wide-canvas pipeline stages to ~/Desktop/VRDesktop-debug so the merge can
    /// be inspected — stage1_*.jpg = each raw screen capture (pre-merge), stage2.jpg = the single
    /// merged flat atlas (before curve), stage3.jpg = the final curved frame sent to the glasses.
    func captureDebugStages() {
        guard let renderer, arActive else {
            statusMessage = "Start AR first to capture debug stages"; return
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/VRDesktop-debug")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Stage 1: each raw source capture (the flat images, before any merge/curve).
        var stage1: [String] = []
        if let ws = workspaceStore.activeWorkspace {
            let anchored = ws.virtualScreens.filter { $0.showInAR && $0.placement != .floating }
            for (i, cfg) in anchored.enumerated() {
                guard let tex = captures[cfg.id]?.latestTexture else { continue }
                let safe = cfg.name.replacingOccurrences(of: "/", with: "-")
                let url = dir.appendingPathComponent("stage1_\(i)_\(safe).jpg")
                if renderer.dumpTexture(tex, to: url) { stage1.append(url.lastPathComponent) }
            }
        }

        // Stage 2 marker crosshairs (atlas pixels, top-left origin):
        //   red  = sphere wrap centre (the atlas/bounding-box centre the canvas curves around)
        //   green = GUI FOV centre (yaw 0, pitch 0 — straight ahead)
        //   blue = current glasses centre (where the head is pointing right now)
        var markers: [(x: Int, y: Int, color: CGColor)] = []
        if wideCanvas, let m = lastCanvasMapping {
            func clamp(_ v: Double, _ hi: Int) -> Int { Int(min(Double(hi - 1), max(0, v))) }
            // Atlas axes: x = (azimuth − aMin)·pxH, y = (−elevation − bMin)·pxV.
            markers.append((clamp((0 - m.aMin) * m.pxH, m.w), clamp((0 - m.bMin) * m.pxV, m.h),
                           NSColor.systemGreen.cgColor))
            markers.append((m.w / 2, m.h / 2, NSColor.systemRed.cgColor))
            let f = simd_normalize(IMUService.shared.poseStore.latest().orientation.act(SIMD3<Float>(0, 0, -1)))
            let azDeg = Double(atan2(f.x, -f.z)) * 180 / .pi
            let elDeg = Double(asin(max(-1, min(1, f.y)))) * 180 / .pi
            markers.append((clamp((azDeg - m.aMin) * m.pxH, m.w), clamp((-elDeg - m.bMin) * m.pxV, m.h),
                           NSColor.systemBlue.cgColor))
        }
        renderer.debugStage2Markers = markers

        // Stages 2 & 3 are captured by the renderer on its next frame (needs the GPU).
        renderer.onDebugDumpComplete = { [weak self] later in
            DispatchQueue.main.async {
                let all = stage1 + later
                self?.statusMessage = "Debug stages → ~/Desktop/VRDesktop-debug: " + all.joined(separator: ", ")
                DebugLog.shared.log("debug stages written: \(all.joined(separator: ", "))")
            }
        }
        renderer.debugDumpDir = dir
        statusMessage = "Capturing debug stages…"
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
        syncPhysicalMonitors() // the new workspace may not have this machine's monitors yet
        objectWillChange.send()
        restartARIfActive()
    }

    func addWorkspace() {
        let ws = Workspace(name: "Workspace \(workspaceStore.workspaces.count + 1)")
        workspaceStore.append(ws)
        workspaceStore.activeWorkspaceID = ws.id
        workspaceStore.save()
        syncPhysicalMonitors() // seed the fresh workspace with this machine's monitors
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
        // Preserve the layout snapshot captured before sleep; the windows are currently scattered
        // onto whatever displays survived, so re-snapshotting now would record the wrong layout.
        restartARIfActive(preserveLayout: true)
    }

    /// Restart AR on the same output so a workspace change rebuilds its virtual displays.
    /// `preserveLayout` keeps the last good window snapshot instead of re-capturing — used on
    /// wake, where the windows have already scattered onto the wrong displays.
    private func restartARIfActive(preserveLayout: Bool = false) {
        guard arActive, lastOutputScreenID != 0 else { return }
        let id = lastOutputScreenID
        stopAR(snapshotLayout: !preserveLayout)
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
        _ = makeCapture(config: config, captureDisplayID: displayID)
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

    /// All editable screens in the active workspace, for the UI list and Layout map: virtual
    /// screens plus connected physical monitors (excluding mirror targets, which are shown via
    /// the virtual screen mirrored onto them).
    func editableScreens() -> [VirtualScreenConfig] {
        guard let ws = workspaceStore.activeWorkspace else { return [] }
        let physical = ws.physicalInAR
            .filter { isLayoutPhysical(uuid: $0.key) }
            .values.sorted { $0.name < $1.name }
        return ws.virtualScreens + physical
    }

    /// True if the screen is a real (physical) monitor mirrored into AR rather than a virtual one.
    func isPhysicalScreen(_ id: UUID) -> Bool {
        workspaceStore.activeWorkspace?.physicalInAR.values.contains { $0.id == id } ?? false
    }

    func bindingForScreen(id: UUID) -> VirtualScreenConfig? {
        guard let ws = workspaceStore.activeWorkspace else { return nil }
        return ws.virtualScreens.first { $0.id == id }
            ?? ws.physicalInAR.values.first { $0.id == id }
    }

    func updateScreen(_ config: VirtualScreenConfig) {
        guard var ws = workspaceStore.activeWorkspace else { return }
        let existing = ws.virtualScreens.first(where: { $0.id == config.id })
        var physicalKey: String?
        let priorShowInAR: Bool?
        if let i = ws.virtualScreens.firstIndex(where: { $0.id == config.id }) {
            priorShowInAR = existing?.showInAR
            ws.virtualScreens[i] = config
        } else if let entry = ws.physicalInAR.first(where: { $0.value.id == config.id }) {
            physicalKey = entry.key
            priorShowInAR = entry.value.showInAR
            ws.physicalInAR[entry.key] = config
        } else {
            return
        }
        workspaceStore.activeWorkspace = ws
        workspaceStore.save()

        let resolutionChanged = existing.map { $0.width != config.width || $0.height != config.height || $0.hiDPI != config.hiDPI } ?? false
        if resolutionChanged {
            if let capture = captures.removeValue(forKey: config.id) {
                Task { await capture.stop() }
            }
            virtualDisplays.destroy(config.id)
            if arActive, config.showInAR,
               let displayID = virtualDisplays.create(config),
               displayID != glassesDisplayID {
                _ = makeCapture(config: config, captureDisplayID: displayID)
            }
        }

        // Physical monitor toggled between positioning-only (green) and mirrored-into-AR
        // (orange) live: start or stop its capture so the change takes effect without a restart.
        if arActive, let uuid = physicalKey, priorShowInAR != config.showInAR {
            if config.showInAR, captures[config.id] == nil,
               let displayID = Self.resolvePhysicalDisplay(uuidString: uuid),
               displayID != glassesDisplayID {
                _ = makeCapture(config: config, captureDisplayID: displayID)
            } else if !config.showInAR, let capture = captures.removeValue(forKey: config.id) {
                Task { await capture.stop() }
            }
        }

        liveUpdateScreens()
    }

    /// Path of the static test image rendered by the dumb-AR experiment.
    static let staticImageURL = URL(fileURLWithPath:
        "/Users/paulketelle/Desktop/VRDesktop-debug/stage2.jpg")

    /// EXPERIMENT (branch: static-image-ar): render ONE static image to the spatial scene with
    /// no capture and no virtual displays. Everything else (display link, output window, head
    /// tracking) is identical to real AR — so if this still jitters, the cause is the AR
    /// presentation path itself, not the capture / virtual-display machinery.
    func startStaticImageAR(on screen: NSScreen) {
        guard let renderer, !arActive else { return }
        guard let tex = renderer.loadTexture(contentsOf: Self.staticImageURL) else {
            statusMessage = "Static AR: couldn't load \(Self.staticImageURL.lastPathComponent)"
            return
        }
        let aspect = Float(tex.width) / Float(max(1, tex.height))
        // A single anchored, auto-curved screen filling the view — mirrors how the real merged
        // canvas is placed, minus all the live machinery.
        let imageScreen = SceneScreen(
            id: UUID(),
            yaw: 0, pitch: 0,
            distance: 2.0,
            widthMeters: 3.2,
            aspect: aspect,
            curveH: 0, autoCurveH: true,
            headLocked: false,
            textureProvider: { tex })
        renderer.setScreens([imageScreen])
        glassesDisplayID = Self.screenDisplayID(screen)
        // Apply the chosen output rate before opening the window (no live link yet → safe).
        if glassesRefreshRate > 0 {
            DisplayModeSwitcher.switchTo(displayID: glassesDisplayID, width: 1920, height: 1080,
                                         refresh: glassesRefreshRate)
        }
        arActive = true
        lastWindowSnapshot = CACurrentMediaTime()
        if arActivity == nil {
            arActivity = ProcessInfo.processInfo.beginActivity(
                options: [.latencyCritical, .userInitiated, .idleSystemSleepDisabled],
                reason: "static image AR experiment")
        }
        renderer.startOutput(on: screen)
        outputScreenName = screen.localizedName
        statusMessage = "Static-image AR on \(screen.localizedName) (\(tex.width)×\(tex.height)) — no capture/virtual displays"
        DebugLog.shared.log("startStaticImageAR on '\(screen.localizedName)' tex=\(tex.width)x\(tex.height)")
    }

    /// Stop AR. `snapshotLayout` records where each app window currently sits so it can be
    /// restored next time — pass false when the windows have ALREADY been scattered (e.g. the
    /// displays dropped out during sleep), so we don't overwrite the good pre-sleep snapshot.
    func stopAR(snapshotLayout: Bool = true) {
        guard arActive else { return }
        DebugLog.shared.log("stopAR(snapshotLayout: \(snapshotLayout))")
        // Record which apps are on which screen BEFORE the virtual displays are destroyed
        // (destroying them makes macOS scatter their windows onto other displays).
        if snapshotLayout { snapshotWindowLayout() }
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
        // Put the user's real desktop arrangement back the way it was before AR moved things.
        restoreDisplayArrangement()
        glassesDisplayID = 0
        arActive = false
        lastArrangementSignature = []
        outputScreenName = nil
        statusMessage = "AR stopped"
    }

    func saveWorkspaces() { workspaceStore.save() }

    func moveOutputWindow(x: Double, y: Double) {
        renderer?.moveOutput(to: CGPoint(x: x, y: y))
    }
}

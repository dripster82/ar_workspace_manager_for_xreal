import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One-time rebrand migration: move the app's data folder from the old "VRDesktop" name to
/// "AR Workspace Manager" so saved workspaces, window layouts, and backgrounds carry over. Runs
/// before any store reads its path. Keychain secrets migrate separately in SecretStore.
private func migrateAppSupportFolderIfNeeded() {
    let fm = FileManager.default
    guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    let old = base.appendingPathComponent("VRDesktop", isDirectory: true)
    let new = base.appendingPathComponent("AR Workspace Manager", isDirectory: true)
    guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
    try? fm.moveItem(at: old, to: new)
}
migrateAppSupportFolderIfNeeded()

// Programmatic app entry (no @main attribute conflicts with SwiftPM main.swift).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var coordinator: AppCoordinator!
    var statusItem: NSStatusItem!
    let brightnessHotKey = BrightnessHotKey()
    var helpOverlay: HelpOverlayController!
    var cursorInfoOverlay: CursorInfoOverlayController!
    var windowPicker: WindowPickerController!
    var brightnessHUD: BrightnessHUDController!
    var alarmController: AlarmController!
    var calibrationController: CalibrationController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
        coordinator = AppCoordinator()
        coordinator.checkForUpdates()   // silent on launch; surfaces in the menu + About page

        // After a self-update the bundle (incl. the privileged helper) changed — refresh the daemon.
        let versionKey = "lastLaunchedVersion"
        let previous = UserDefaults.standard.string(forKey: versionKey)
        if let previous, previous != coordinator.appVersion {
            PrivilegedHelperClient.shared.refreshAfterUpdateIfRegistered()
        }
        UserDefaults.standard.set(coordinator.appVersion, forKey: versionKey)
        helpOverlay = HelpOverlayController(coordinator: coordinator)
        cursorInfoOverlay = CursorInfoOverlayController(coordinator: coordinator)
        windowPicker = WindowPickerController(coordinator: coordinator)
        brightnessHUD = BrightnessHUDController(coordinator: coordinator)
        coordinator.onBrightnessChanged = { [weak self] in self?.brightnessHUD.flash() }
        alarmController = AlarmController(coordinator: coordinator)
        alarmController.escArmer = { [weak self] on in
            self?.escForAlarm = on
            self?.updateEscArming()
        }
        // Esc also escapes Focus mode (which confines the cursor to the focused screen) — otherwise
        // the only exit is ⌃⌥F, which is easy to miss and unreachable if the cursor is trapped away
        // from the control panel.
        coordinator.onFocusChanged = { [weak self] focused in
            guard let self else { return }
            switch self.coordinator.focusEscape {
            case .fnFOnly:
                self.escForFocus = false
                self.stopDoubleEscTap()
            case .singleEsc:
                self.escForFocus = focused          // single Esc exits (consumes Esc)
                self.stopDoubleEscTap()
            case .doubleEsc:
                self.escForFocus = false            // don't consume Esc; observe instead
                if focused { self.startDoubleEscTap() } else { self.stopDoubleEscTap() }
            }
            self.updateEscArming()
        }
        calibrationController = CalibrationController(coordinator: coordinator)
        coordinator.onCalibrationRequested = { [weak self] firstUse, onSuccess in
            self?.calibrationController.show(firstUse: firstUse, onSuccess: onSuccess)
        }
        coordinator.onToggleHelp = { [weak self] in self?.helpOverlay.toggle() }
        coordinator.onToggleCursorInfo = { [weak self] in self?.cursorInfoOverlay.toggle() }
        coordinator.onToggleWindowPicker = { [weak self] in self?.windowPicker.toggle() }
        coordinator.calendar.onAlarm = { [weak self] event, lead in
            self?.alarmController.fire(event: event, leadMinutes: lead)
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "AR Workspace Manager"
        window.isReleasedWhenClosed = false // keep it so the menu bar can reopen it
        window.contentView = NSHostingView(rootView: ControlPanelView(coordinator: coordinator))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        setupMainMenu()
        setupMenuBar()
        registerGlobalRecenterHotKey()
        startBrightnessHotKey()

        // Ask for Screen Recording up front so it's granted before the user ever hits Start AR —
        // rather than discovering the requirement mid-start. No-op once the choice has been made.
        coordinator.requestScreenRecordingAtLaunch()
    }

    /// Install a standard main menu with an Edit menu so ⌘X/⌘C/⌘V/⌘A/⌘Z route to the focused
    /// text field (without it, copy/paste don't work in the Control Panel's fields).
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide AR Workspace Manager", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AR Workspace Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    @MainActor private func startBrightnessHotKey() {
        // Starts only if Accessibility is already granted; otherwise the user enables it
        // from the control panel's "Grant" button (no auto-prompt at launch).
        brightnessHotKey.start { [weak self] up in
            MainActor.assumeIsolated { self?.coordinator.adjustBrightness(up: up) }
        }
    }

    // System-wide hotkeys (work while any app is focused):
    // ⌃⌥Space → recenter, ⌃⌥Esc → stop AR.
    private var recenterHotKeyRef: EventHotKeyRef?
    private var stopARHotKeyRef: EventHotKeyRef?
    private static let hotKeySignature = OSType(0x56524454) // 'VRDT'
    private var helpHotKeyRef: EventHotKeyRef?
    private var toggleARHotKeyRef: EventHotKeyRef?
    private var sbsHotKeyRef: EventHotKeyRef?
    private var quitHotKeyRef: EventHotKeyRef?
    private var cursorInfoHotKeyRef: EventHotKeyRef?
    private var cursorToGazeHotKeyRef: EventHotKeyRef?
    private var escDismissHotKeyRef: EventHotKeyRef?
    private var screenshotHotKeyRef: EventHotKeyRef?
    private var recordHotKeyRef: EventHotKeyRef?
    private var micMuteHotKeyRef: EventHotKeyRef?
    private var toggleHUDHotKeyRef: EventHotKeyRef?
    private var toggleFocusHotKeyRef: EventHotKeyRef?
    private var passthroughHotKeyRef: EventHotKeyRef?
    private var labelsHotKeyRef: EventHotKeyRef?
    private var windowPickerHotKeyRef: EventHotKeyRef?
    private var recalibrateHotKeyRef: EventHotKeyRef?
    private var pushToTalkHotKeyRef: EventHotKeyRef?
    private var mediaPos1Ref, mediaPos2Ref, mediaPos3Ref, mediaPos4Ref, mediaPos5Ref: EventHotKeyRef?
    private var mediaStopRef, mediaPlayPauseRef, mediaRewindRef, mediaSkipRef: EventHotKeyRef?
    private static let recenterHotKeyID: UInt32 = 1
    private static let stopARHotKeyID: UInt32 = 2
    private static let helpHotKeyID: UInt32 = 3
    private static let toggleARHotKeyID: UInt32 = 4
    private static let sbsHotKeyID: UInt32 = 5
    private static let quitHotKeyID: UInt32 = 6
    private static let cursorInfoHotKeyID: UInt32 = 7
    private static let cursorToGazeHotKeyID: UInt32 = 8
    private static let escDismissHotKeyID: UInt32 = 9
    private static let screenshotHotKeyID: UInt32 = 10
    private static let recordHotKeyID: UInt32 = 11
    private static let micMuteHotKeyID: UInt32 = 12
    private static let toggleHUDHotKeyID: UInt32 = 13
    private static let toggleFocusHotKeyID: UInt32 = 14
    private static let passthroughHotKeyID: UInt32 = 15
    private static let labelsHotKeyID: UInt32 = 16
    private static let windowPickerHotKeyID: UInt32 = 17
    private static let recalibrateHotKeyID: UInt32 = 18
    private static let pushToTalkHotKeyID: UInt32 = 19
    // Media player: ⌃⌥1–5 = Top-left / Top-right / Bottom-left / Bottom-right / Full view,
    // ⌃⌥0 = Stop, ⌃⌥K = Play/Pause, ⌃⌥← = Rewind 10s, ⌃⌥→ = Skip 10s.
    private static let mediaPos1ID: UInt32 = 20
    private static let mediaPos2ID: UInt32 = 21
    private static let mediaPos3ID: UInt32 = 22
    private static let mediaPos4ID: UInt32 = 23
    private static let mediaPos5ID: UInt32 = 24
    private static let mediaStopID: UInt32 = 25
    private static let mediaPlayPauseID: UInt32 = 26
    private static let mediaRewindID: UInt32 = 27
    private static let mediaSkipID: UInt32 = 28

    private func registerGlobalRecenterHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                // Until AR is running, only these work: Help, Quit, Start/Stop AR, Recalibrate (and
                // the Esc-to-dismiss helper for the overlays). Every other shortcut is inert — there's
                // no AR session for it to act on. Keep this in sync with the dashboard's `arOnly` tiles.
                let alwaysAllowed: Set<UInt32> = [
                    AppDelegate.helpHotKeyID, AppDelegate.quitHotKeyID,
                    AppDelegate.toggleARHotKeyID, AppDelegate.stopARHotKeyID,
                    AppDelegate.recalibrateHotKeyID, AppDelegate.escDismissHotKeyID,
                    AppDelegate.pushToTalkHotKeyID,
                ]
                guard delegate.coordinator.arActive || alwaysAllowed.contains(hotKeyID.id) else { return }
                switch hotKeyID.id {
                case AppDelegate.recenterHotKeyID: delegate.coordinator.recenter()
                case AppDelegate.stopARHotKeyID: delegate.coordinator.stopAR()
                case AppDelegate.helpHotKeyID: delegate.helpOverlay.toggle()
                case AppDelegate.toggleARHotKeyID: delegate.toggleAR()
                case AppDelegate.sbsHotKeyID:
                    delegate.coordinator.setStereo(!delegate.coordinator.stereoEnabled)
                case AppDelegate.cursorInfoHotKeyID: delegate.cursorInfoOverlay.toggle()
                case AppDelegate.cursorToGazeHotKeyID: delegate.coordinator.moveCursorToGaze()
                case AppDelegate.escDismissHotKeyID: delegate.handleEscPressed()
                case AppDelegate.screenshotHotKeyID: delegate.coordinator.takeGlassesScreenshot()
                case AppDelegate.recordHotKeyID: delegate.coordinator.toggleRecording()
                case AppDelegate.micMuteHotKeyID: delegate.coordinator.toggleMicMute()
                case AppDelegate.toggleHUDHotKeyID: delegate.coordinator.toggleHUD()
                case AppDelegate.toggleFocusHotKeyID: delegate.coordinator.toggleFocus()
                case AppDelegate.passthroughHotKeyID: delegate.coordinator.togglePassthrough()
                case AppDelegate.labelsHotKeyID: delegate.coordinator.toggleLabels()
                case AppDelegate.windowPickerHotKeyID: delegate.windowPicker.toggle()
                case AppDelegate.recalibrateHotKeyID: delegate.coordinator.requestCalibration()
                case AppDelegate.pushToTalkHotKeyID: delegate.coordinator.startPushToTalk()
                case AppDelegate.mediaPos1ID: delegate.coordinator.setMediaPosition(.topLeft)
                case AppDelegate.mediaPos2ID: delegate.coordinator.setMediaPosition(.topRight)
                case AppDelegate.mediaPos3ID: delegate.coordinator.setMediaPosition(.bottomLeft)
                case AppDelegate.mediaPos4ID: delegate.coordinator.setMediaPosition(.bottomRight)
                case AppDelegate.mediaPos5ID: delegate.coordinator.setMediaPosition(.fullFOV)
                case AppDelegate.mediaStopID: delegate.coordinator.stopMedia()
                case AppDelegate.mediaPlayPauseID: delegate.coordinator.toggleMediaPlay()
                case AppDelegate.mediaRewindID: delegate.coordinator.mediaSkip(-10)
                case AppDelegate.mediaSkipID: delegate.coordinator.mediaSkip(10)
                case AppDelegate.quitHotKeyID: NSApp.terminate(nil)
                default: break
                }
            }
            return noErr
        }, 1, &eventType, selfPtr, nil)

        let register = { (keyCode: Int, id: UInt32, ref: inout EventHotKeyRef?) in
            let hotKeyID = EventHotKeyID(signature: AppDelegate.hotKeySignature, id: id)
            let status = RegisterEventHotKey(UInt32(keyCode),
                                             UInt32(controlKey | optionKey),
                                             hotKeyID, GetEventDispatcherTarget(), 0, &ref)
            if status != noErr {
                NSLog("Global hotkey \(id) registration failed: \(status)")
            }
        }
        register(kVK_Space, AppDelegate.recenterHotKeyID, &recenterHotKeyRef)
        register(kVK_Escape, AppDelegate.stopARHotKeyID, &stopARHotKeyRef)
        register(kVK_ANSI_H, AppDelegate.helpHotKeyID, &helpHotKeyRef)
        register(kVK_ANSI_S, AppDelegate.toggleARHotKeyID, &toggleARHotKeyRef)
        register(kVK_ANSI_D, AppDelegate.sbsHotKeyID, &sbsHotKeyRef)
        register(kVK_ANSI_Q, AppDelegate.quitHotKeyID, &quitHotKeyRef)
        register(kVK_ANSI_C, AppDelegate.cursorInfoHotKeyID, &cursorInfoHotKeyRef)
        register(kVK_ANSI_X, AppDelegate.cursorToGazeHotKeyID, &cursorToGazeHotKeyRef)
        register(kVK_ANSI_P, AppDelegate.screenshotHotKeyID, &screenshotHotKeyRef)
        register(kVK_ANSI_R, AppDelegate.recordHotKeyID, &recordHotKeyRef)
        register(kVK_ANSI_M, AppDelegate.micMuteHotKeyID, &micMuteHotKeyRef)
        register(kVK_ANSI_I, AppDelegate.toggleHUDHotKeyID, &toggleHUDHotKeyRef)
        register(kVK_ANSI_F, AppDelegate.toggleFocusHotKeyID, &toggleFocusHotKeyRef)
        register(kVK_ANSI_V, AppDelegate.passthroughHotKeyID, &passthroughHotKeyRef)
        register(kVK_ANSI_L, AppDelegate.labelsHotKeyID, &labelsHotKeyRef)
        register(kVK_ANSI_W, AppDelegate.windowPickerHotKeyID, &windowPickerHotKeyRef)
        register(kVK_ANSI_B, AppDelegate.recalibrateHotKeyID, &recalibrateHotKeyRef)
        register(kVK_ANSI_A, AppDelegate.pushToTalkHotKeyID, &pushToTalkHotKeyRef)
        register(kVK_ANSI_1, AppDelegate.mediaPos1ID, &mediaPos1Ref)
        register(kVK_ANSI_2, AppDelegate.mediaPos2ID, &mediaPos2Ref)
        register(kVK_ANSI_3, AppDelegate.mediaPos3ID, &mediaPos3Ref)
        register(kVK_ANSI_4, AppDelegate.mediaPos4ID, &mediaPos4Ref)
        register(kVK_ANSI_5, AppDelegate.mediaPos5ID, &mediaPos5Ref)
        register(kVK_ANSI_0, AppDelegate.mediaStopID, &mediaStopRef)
        register(kVK_ANSI_K, AppDelegate.mediaPlayPauseID, &mediaPlayPauseRef)
        register(kVK_LeftArrow, AppDelegate.mediaRewindID, &mediaRewindRef)
        register(kVK_RightArrow, AppDelegate.mediaSkipID, &mediaSkipRef)
    }

    /// A plain Escape hotkey is registered only while it's actually wanted — when an alarm is
    /// showing OR Focus mode is active — so it doesn't swallow Esc the rest of the time.
    private var escForAlarm = false
    private var escForFocus = false

    @MainActor func updateEscArming() {
        if escForAlarm || escForFocus { registerEscDismiss() } else { unregisterEscDismiss() }
    }

    /// Route a plain-Esc press: dismiss an active alarm first, otherwise exit Focus mode.
    @MainActor func handleEscPressed() {
        if escForAlarm { alarmController.dismiss() } else { coordinator.exitFocus() }
    }

    @MainActor func registerEscDismiss() {
        guard escDismissHotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: AppDelegate.hotKeySignature, id: AppDelegate.escDismissHotKeyID)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetEventDispatcherTarget(), 0, &escDismissHotKeyRef)
    }

    @MainActor func unregisterEscDismiss() {
        if let ref = escDismissHotKeyRef { UnregisterEventHotKey(ref); escDismissHotKeyRef = nil }
    }

    // MARK: Double-tap Esc (observe-only)
    // A passive event tap that watches Esc WITHOUT consuming it, so single Esc still reaches the
    // focused app; only a quick double-press exits Focus. Active only while Focus is on in that mode.
    private var doubleEscTap: CFMachPort?
    private var doubleEscSource: CFRunLoopSource?
    private var lastEscTime: CFTimeInterval = 0

    @MainActor func startDoubleEscTap() {
        guard doubleEscTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if type == .keyDown,
                   event.getIntegerValueField(.keyboardEventKeycode) == 53,   // Esc
                   let userInfo {
                    let d = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
                    DispatchQueue.main.async { d.handleEscObserved() }
                }
                return Unmanaged.passUnretained(event)   // never consume — app still gets Esc
            }, userInfo: me) else {
            NSLog("Double-tap Esc tap failed (needs Accessibility) — Focus exit via ⌃⌥F only")
            return
        }
        doubleEscTap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        doubleEscSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    @MainActor func stopDoubleEscTap() {
        if let tap = doubleEscTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = doubleEscSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        doubleEscTap = nil
        doubleEscSource = nil
        lastEscTime = 0
    }

    @MainActor func handleEscObserved() {
        let now = CACurrentMediaTime()
        if now - lastEscTime < 0.4 {   // second press within the window → exit Focus
            lastEscTime = 0
            coordinator.exitFocus()
        } else {
            lastEscTime = now
        }
    }

    // MARK: Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eyeglasses",
                                           accessibilityDescription: "AR Workspace Manager")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // we drive isEnabled ourselves (AR-only items)
        statusItem.menu = menu
    }

    // Rebuild the menu each time it opens so labels/state reflect the current session.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ar = coordinator.arActive

        // Adds an item; `enabled` gates AR-only actions, `state` shows a checkmark.
        @discardableResult
        func add(_ title: String, _ sel: Selector?, enabled: Bool = true,
                 state: NSControl.StateValue = .off) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = sel == nil ? nil : self
            it.isEnabled = enabled
            it.state = state
            menu.addItem(it)
            return it
        }

        let status: String
        switch coordinator.glassesState {
        case .connected(let p): status = "Glasses: \(p)"
        case .disconnected: status = "Glasses: not connected"
        case .error(let e): status = "Glasses: \(e)"
        }
        add(status, nil, enabled: false)
        menu.addItem(.separator())

        add("Open AR Workspace Manager", #selector(openWindow))
        if let v = coordinator.updateAvailableVersion, coordinator.updateURL != nil {
            add("⬇ Update available: v\(v) — Update…", #selector(openUpdatePage))
        }
        menu.addItem(.separator())

        // AR & view
        add(ar ? "Stop AR  (⌃⌥S)" : "Start AR  (⌃⌥S)", #selector(toggleAR))
        add("Recenter  (⌃⌥Space)", #selector(menuRecenter), enabled: ar)
        add("Recalibrate drift  (⌃⌥B)", #selector(menuRecalibrate))
        add("Focus looked-at screen  (⌃⌥F)", #selector(menuToggleFocus), enabled: ar)
        add("Passthrough  (⌃⌥V)", #selector(menuTogglePassthrough), enabled: ar)
        add(coordinator.stereoEnabled ? "Disable Stereo (SBS)  (⌃⌥D)" : "Enable Stereo (SBS)  (⌃⌥D)",
            #selector(toggleSBS), enabled: ar)
        menu.addItem(.separator())

        // HUD
        add("Toggle HUD Widgets  (⌃⌥I)", #selector(menuToggleHUD), enabled: ar)
        add("Toggle Screen Labels  (⌃⌥L)", #selector(menuToggleLabels), enabled: ar)
        menu.addItem(.separator())

        // Cursor & windows
        add("Where's My Cursor?  (⌃⌥C)", #selector(toggleCursorInfo), enabled: ar)
        add("Move Cursor to Gaze  (⌃⌥X)", #selector(moveCursorToGaze), enabled: ar)
        add("Move Window to Gaze  (⌃⌥W)", #selector(menuWindowPicker), enabled: ar)
        menu.addItem(.separator())

        // Capture
        add("Screenshot Glasses View  (⌃⌥P)", #selector(menuScreenshot), enabled: ar)
        add("Record Glasses View  (⌃⌥R)", #selector(menuRecord), enabled: ar)
        add("Mute / Unmute Mic  (⌃⌥M)", #selector(menuMicMute), enabled: ar)
        menu.addItem(.separator())

        add("Keyboard Shortcuts  (⌃⌥H)", #selector(toggleHelp))
        add("Launch at Login", #selector(toggleLaunchAtLogin),
            state: coordinator.launchAtLogin ? .on : .off)
        menu.addItem(.separator())
        add("Quit AR Workspace Manager  (⌃⌥Q)", #selector(NSApplication.terminate(_:))).target = nil
    }

    @MainActor @objc private func openWindow() {
        placeWindowUnderCursor()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open on the screen under the cursor. While AR is running, never the AR output screen.
    @MainActor private func placeWindowUnderCursor() {
        let origin = WindowPlacement.originUnderCursor(
            size: window.frame.size, excluding: coordinator.arOutputDisplayID)
        window.setFrameOrigin(origin)
    }

    @MainActor @objc func toggleAR() {
        if coordinator.arActive {
            coordinator.stopAR()
        } else if let id = coordinator.glassesScreenID()
                    ?? NSScreen.screens.first(where: { $0 != NSScreen.main })
                        .map({ AppCoordinator.screenDisplayID($0) }),
                  let screen = NSScreen.screens.first(where: { AppCoordinator.screenDisplayID($0) == id }) {
            coordinator.startAR(on: screen)
        } else {
            coordinator.statusMessage = "No glasses/output display found"
            openWindow()
        }
    }

    @MainActor @objc private func menuRecenter() { coordinator.recenter() }

    @MainActor @objc private func toggleHelp() { helpOverlay.toggle() }

    @MainActor @objc private func toggleCursorInfo() { cursorInfoOverlay.toggle() }

    @MainActor @objc private func moveCursorToGaze() { coordinator.moveCursorToGaze() }

    @MainActor @objc private func toggleSBS() { coordinator.setStereo(!coordinator.stereoEnabled) }

    @MainActor @objc private func toggleLaunchAtLogin() { coordinator.launchAtLogin.toggle() }

    @MainActor @objc private func menuRecalibrate() { coordinator.requestCalibration() }
    @MainActor @objc private func menuToggleFocus() { coordinator.toggleFocus() }
    @MainActor @objc private func menuTogglePassthrough() { coordinator.togglePassthrough() }
    @MainActor @objc private func menuToggleHUD() { coordinator.toggleHUD() }
    @MainActor @objc private func menuToggleLabels() { coordinator.toggleLabels() }
    @MainActor @objc private func menuWindowPicker() { windowPicker.toggle() }
    @MainActor @objc private func menuScreenshot() { coordinator.takeGlassesScreenshot() }
    @MainActor @objc private func menuRecord() { coordinator.toggleRecording() }
    @MainActor @objc private func menuMicMute() { coordinator.toggleMicMute() }
    @MainActor @objc private func openUpdatePage() {
        // Open the in-app About page (Settings → About) where Download & Install lives.
        coordinator.pendingRoute = .settings
        coordinator.pendingSettingsTab = .about
        openWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.voice.stop()
        coordinator.stopAR()
        coordinator.saveWorkspaces()
    }

    // Keep running in the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

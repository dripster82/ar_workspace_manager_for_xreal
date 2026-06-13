import AppKit
import Carbon.HIToolbox
import SwiftUI

// Programmatic app entry (no @main attribute conflicts with SwiftPM main.swift).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var coordinator: AppCoordinator!
    var hotKeyMonitor: Any?
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "VR Desktop"
        window.isReleasedWhenClosed = false // keep it so the menu bar can reopen it
        window.contentView = NSHostingView(rootView: ControlPanelView(coordinator: coordinator))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        setupMenuBar()
        registerGlobalRecenterHotKey()

        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc stops AR output.
            if event.keyCode == UInt16(kVK_Escape), self?.coordinator.arActive == true {
                self?.coordinator.stopAR()
                return nil
            }
            return event
        }
    }

    // System-wide hotkeys (work while any app is focused):
    // ⌃⌥Space → recenter, ⌃⌥Esc → stop AR.
    private var recenterHotKeyRef: EventHotKeyRef?
    private var stopARHotKeyRef: EventHotKeyRef?
    private static let hotKeySignature = OSType(0x56524454) // 'VRDT'
    private static let recenterHotKeyID: UInt32 = 1
    private static let stopARHotKeyID: UInt32 = 2

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
                switch hotKeyID.id {
                case AppDelegate.recenterHotKeyID: delegate.coordinator.recenter()
                case AppDelegate.stopARHotKeyID: delegate.coordinator.stopAR()
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
    }

    // MARK: Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eyeglasses",
                                           accessibilityDescription: "VR Desktop")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild the menu each time it opens so labels/checkmarks reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        switch coordinator.glassesState {
        case .connected(let p): status = "Glasses: \(p)"
        case .disconnected: status = "Glasses: not connected"
        case .error(let e): status = "Glasses: \(e)"
        }
        let statusEntry = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusEntry.isEnabled = false
        menu.addItem(statusEntry)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Open VR Desktop", action: #selector(openWindow), keyEquivalent: "")
            .target = self
        let arItem = NSMenuItem(title: coordinator.arActive ? "Stop AR" : "Start AR",
                                action: #selector(toggleAR), keyEquivalent: "")
        arItem.target = self
        menu.addItem(arItem)
        let recenter = NSMenuItem(title: "Recenter", action: #selector(menuRecenter), keyEquivalent: "")
        recenter.target = self
        menu.addItem(recenter)

        menu.addItem(.separator())
        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin),
                                keyEquivalent: "")
        launch.target = self
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VR Desktop", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    @MainActor @objc private func openWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc private func toggleAR() {
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

    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.set(!LaunchAtLogin.isEnabled) }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stopAR()
        coordinator.saveWorkspaces()
    }

    // Keep running in the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

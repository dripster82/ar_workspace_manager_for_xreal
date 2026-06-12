import AppKit
import Carbon.HIToolbox
import SwiftUI

// Programmatic app entry (no @main attribute conflicts with SwiftPM main.swift).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var coordinator: AppCoordinator!
    var hotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "VR Desktop"
        window.contentView = NSHostingView(rootView: ControlPanelView(coordinator: coordinator))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

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

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stopAR()
        coordinator.saveWorkspaces()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

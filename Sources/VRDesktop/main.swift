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

        // ⌃⌥Space → recenter (local monitor; global recenter can come later).
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Space),
               event.modifierFlags.contains([.control, .option]) {
                self?.coordinator.recenter()
                return nil
            }
            // Esc stops AR output.
            if event.keyCode == UInt16(kVK_Escape), self?.coordinator.arActive == true {
                self?.coordinator.stopAR()
                return nil
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stopAR()
        coordinator.saveWorkspaces()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

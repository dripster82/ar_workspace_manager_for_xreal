import AppKit
import SwiftUI

/// Toggles the help display: an in-AR screen-space overlay while AR is running, or a
/// floating macOS panel when it isn't.
@MainActor
final class HelpOverlayController {
    private let coordinator: AppCoordinator
    private var panel: NSPanel?
    private(set) var visible = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func toggle() {
        visible ? hide() : show()
    }

    func show() {
        visible = true
        if coordinator.arActive, let renderer = coordinator.renderer,
           let image = HelpContent.renderCGImage() {
            renderer.setHelpImage(image)
        } else {
            showPanel()
        }
    }

    func hide() {
        visible = false
        coordinator.renderer?.clearHelp()
        panel?.orderOut(nil)
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Centre on the screen under the cursor, never the AR output.
        let size = panel.frame.size
        panel.setFrameOrigin(ScreenPlacement.originUnderCursor(
            size: size, excluding: coordinator.arOutputDisplayID))
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: HelpView())
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        // Borderless (no title bar) — the HelpView draws its own rounded card; close with ⌃⌥H.
        let panel = NSPanel(contentRect: hosting.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hosting
        return panel
    }
}

/// Shared placement: window origin centered on the screen under the cursor, excluding a display.
enum ScreenPlacement {
    @MainActor
    static func originUnderCursor(size: NSSize, excluding excludedID: CGDirectDisplayID?) -> NSPoint {
        let cursor = NSEvent.mouseLocation
        let allowed = NSScreen.screens.filter {
            AppCoordinator.screenDisplayID($0) != excludedID
        }
        let target = allowed.first { NSMouseInRect(cursor, $0.frame, false) }
            ?? allowed.first { $0 == NSScreen.main }
            ?? allowed.first
            ?? NSScreen.main
        let frame = target?.frame ?? .zero
        return NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
    }
}

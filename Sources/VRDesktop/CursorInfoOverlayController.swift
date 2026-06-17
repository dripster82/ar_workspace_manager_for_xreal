import AppKit
import SwiftUI

/// Toggles the cursor-info popup: an in-AR screen-space overlay while AR is running, or a
/// floating macOS panel when it isn't. Each show captures the cursor's current screen and
/// coordinates, so pressing ⌃⌥C again refreshes the readout.
@MainActor
final class CursorInfoOverlayController {
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
        let info = CursorInfo.current(arOutputDisplayID: coordinator.arOutputDisplayID)
        visible = true
        if coordinator.arActive, let renderer = coordinator.renderer,
           let image = info.renderCGImage(), renderer.setHelpImage(image) {
            // Shown as the in-AR overlay (shares the help overlay slot).
        } else {
            showPanel(info) // AR off, or overlay couldn't be built — use the macOS panel
        }
    }

    func hide() {
        visible = false
        coordinator.renderer?.clearHelp()
        panel?.orderOut(nil)
    }

    private func showPanel(_ info: CursorInfo) {
        let hosting = NSHostingView(rootView: CursorInfoView(info: info))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        // Centre on the screen under the cursor, never the AR output.
        panel.setFrameOrigin(WindowPlacement.originUnderCursor(
            size: panel.frame.size, excluding: coordinator.arOutputDisplayID))
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        return panel
    }
}

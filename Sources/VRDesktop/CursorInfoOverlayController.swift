import AppKit
import SwiftUI
import DisplayManager

/// Toggles the cursor-info popup: an in-AR screen-space overlay while AR is running, or a
/// floating macOS panel when it isn't. While visible it auto-refreshes ~every 0.5s so the
/// screen names and direction arrow track head movement live; press ⌃⌥C again to close.
/// While open it also enlarges the system cursor so it's easy to spot in the glasses.
@MainActor
final class CursorInfoOverlayController {
    private let coordinator: AppCoordinator
    private var panel: NSPanel?
    private var hosting: NSHostingView<CursorInfoView>?
    private var refreshTimer: Timer?
    private(set) var visible = false

    /// How much to enlarge the cursor while searching, and the scale to restore on close.
    private let searchCursorScale: Float = 2.5
    private var savedCursorScale: Float?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func toggle() {
        visible ? hide() : show()
    }

    func show() {
        visible = true
        // Enlarge the system cursor (captured into AR) so it's easy to find. Remember the user's
        // current scale so we can restore it exactly on close.
        if savedCursorScale == nil { savedCursorScale = CursorScale.current }
        CursorScale.set(searchCursorScale)
        refresh()
        // Light 2 Hz refresh — a direct texture upload / rootView swap, not an @Published write,
        // so it doesn't re-render the Control Panel or disturb the render display link.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func hide() {
        visible = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        // Restore the cursor to the size it was before searching.
        if let saved = savedCursorScale { CursorScale.set(saved); savedCursorScale = nil }
        coordinator.renderer?.clearHelp()
        panel?.orderOut(nil)
    }

    /// Re-sample the cursor + gaze + direction and update whichever surface is showing.
    private func refresh() {
        guard visible else { return }
        let info = CursorInfo.current(arOutputDisplayID: coordinator.arOutputDisplayID)
        let gaze = coordinator.currentGaze()
        // Cursor's fractional position on its display (top-left origin), for the eye→cursor arrow.
        let u = info.screenSize.width > 0 ? Double(info.local.x / info.screenSize.width) : 0.5
        let v = info.screenSize.height > 0 ? Double(info.local.y / info.screenSize.height) : 0.5
        let direction = coordinator.cursorDirection(onDisplayID: info.displayID, u: u, v: v)
        let view = CursorInfoView(info: info, gaze: gaze, direction: direction)

        if coordinator.arActive, let renderer = coordinator.renderer,
           let image = info.renderCGImage(gaze: gaze, direction: direction),
           renderer.setHelpImage(image) {
            // In-AR overlay (shares the help overlay slot). Hide the panel if AR just came on.
            panel?.orderOut(nil)
        } else {
            coordinator.renderer?.clearHelp()
            showPanel(view)
        }
    }

    private func showPanel(_ view: CursorInfoView) {
        let hosting = self.hosting ?? NSHostingView(rootView: view)
        hosting.rootView = view
        self.hosting = hosting
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.contentView !== hosting { panel.contentView = hosting }
        panel.setContentSize(hosting.fittingSize)
        if !panel.isVisible {
            // Centre on the screen under the cursor, never the AR output. Only on first show so the
            // panel doesn't jump around as it auto-refreshes.
            panel.setFrameOrigin(WindowPlacement.originUnderCursor(
                size: panel.frame.size, excluding: coordinator.arOutputDisplayID))
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
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

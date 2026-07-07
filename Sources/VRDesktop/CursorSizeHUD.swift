import AppKit
import SwiftUI
import DisplayManager

/// A small flash shown when the cursor size is stepped with ⌃⌥+ / ⌃⌥− — in-AR (bottom-centre,
/// reusing the brightness HUD's renderer slot: both are transient flashes and never meaningfully
/// coexist) or as a floating macOS panel when AR is off. Shows the offset in steps from the
/// normal cursor size ("+3", "0"). Auto-hides.
@MainActor
final class CursorSizeHUDController {
    private let coordinator: AppCoordinator
    private var panel: NSPanel?
    private var hosting: NSHostingView<CursorSizeHUDView>?
    private var hideTimer: Timer?
    private let visibleDuration: TimeInterval = 1.4

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    /// Show (or refresh) the HUD for the given step offset, then auto-hide.
    func flash(steps: Int) {
        let view = CursorSizeHUDView(steps: steps, atMax: CursorScale.current >= 3.99)

        if coordinator.arActive, let renderer = coordinator.renderer,
           let image = render(view), renderer.setBrightnessImage(image) {
            panel?.orderOut(nil)
        } else {
            showPanel(view)
        }

        hideTimer?.invalidate()
        let timer = Timer(timeInterval: visibleDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        coordinator.renderer?.clearBrightness()
        panel?.orderOut(nil)
    }

    private func render(_ view: CursorSizeHUDView) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.cgImage
    }

    private func showPanel(_ view: CursorSizeHUDView) {
        let hosting = self.hosting ?? NSHostingView(rootView: view)
        hosting.rootView = view
        self.hosting = hosting
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.contentView !== hosting { panel.contentView = hosting }
        panel.setContentSize(hosting.fittingSize)
        panel.setFrameOrigin(WindowPlacement.originUnderCursor(
            size: panel.frame.size, excluding: coordinator.arOutputDisplayID))
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 44),
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

/// Capsule content: cursor icon + "Cursor size" + the step offset from normal.
struct CursorSizeHUDView: View {
    let steps: Int
    let atMax: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow")
            Text("Cursor size")
            Text(steps > 0 ? "+\(steps)" : "\(steps)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(steps == 0 ? Color.secondary : (atMax ? .orange : .white))
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }
}

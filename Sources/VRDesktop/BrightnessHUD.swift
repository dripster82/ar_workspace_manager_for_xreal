import AppKit
import SwiftUI

/// A small brightness bar shown briefly when the glasses brightness changes — in-AR (bottom-centre
/// of the FOV) while a session is running, or as a floating macOS panel when it isn't. Auto-hides.
@MainActor
final class BrightnessHUDController {
    private let coordinator: AppCoordinator
    private var panel: NSPanel?
    private var hosting: NSHostingView<BrightnessHUDView>?
    private var hideTimer: Timer?
    private let visibleDuration: TimeInterval = 1.4

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    /// Show (or refresh) the brightness HUD at the current level, then auto-hide after a moment.
    func flash() {
        let level = Int(coordinator.glassesBrightness.rounded())
        let view = BrightnessHUDView(level: level, maxLevel: AppCoordinator.brightnessMaxLevel)

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

    private func render(_ view: BrightnessHUDView) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.cgImage
    }

    private func showPanel(_ view: BrightnessHUDView) {
        let hosting = self.hosting ?? NSHostingView(rootView: view)
        hosting.rootView = view
        self.hosting = hosting
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.contentView !== hosting { panel.contentView = hosting }
        panel.setContentSize(hosting.fittingSize)
        // Bottom-centre of the screen under the cursor, never the AR output.
        let size = panel.frame.size
        let screen = NSScreen.screens.first {
            AppCoordinator.screenDisplayID($0) != coordinator.arOutputDisplayID
                && NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 80))
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
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

/// The brightness bar: a sun icon, a progress capsule, and the level (shown 1…maxLevel+1 to match
/// the Control Panel slider). `level` and `maxLevel` are the device range (0…8).
struct BrightnessHUDView: View {
    let level: Int
    let maxLevel: Int

    private var fraction: CGFloat {
        maxLevel > 0 ? CGFloat(level) / CGFloat(maxLevel) : 0
    }

    var body: some View {
        let barWidth: CGFloat = 240
        return HStack(spacing: 14) {
            Image(systemName: "sun.max.fill").font(.system(size: 18))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(width: barWidth, height: 10)
                Capsule().fill(.white).frame(width: max(10, barWidth * fraction), height: 10)
            }
            .frame(width: barWidth)
            Text("\(level + 1)").font(.headline.monospacedDigit()).frame(width: 24)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .foregroundStyle(.white)
    }
}

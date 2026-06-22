import AppKit
import SwiftUI

/// Borderless panel that can still become key (so it receives arrow/Return/Esc) — borderless
/// windows refuse key status unless this is overridden.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The ⌃⌥W window picker: a 5×3 grid of window thumbnails. Arrow keys move the highlight, Return
/// moves the chosen window to the screen you're looking at, Esc/⌃⌥W cancels. Renders as an in-AR
/// overlay while AR is running and as a macOS panel otherwise; the (key) panel captures the keys
/// either way, and the previously-active app is restored on close.
@MainActor
final class WindowPickerController {
    private let coordinator: AppCoordinator
    private var panel: KeyablePanel?
    private var hosting: NSHostingView<WindowPickerContent>?
    private var keyMonitor: Any?
    private var footerTimer: Timer?
    private var previousApp: NSRunningApplication?
    private(set) var visible = false

    private var items: [WinItem] = []
    private var selected = 0
    private var loading = false
    private var generation = 0           // bumps each open; ignores stale async thumbnail fills
    private var centeredPanel = false

    private let perPage = 15
    private let cols = 5

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func toggle() { visible ? hide() : show() }

    func show() {
        guard !visible else { return }
        visible = true
        generation += 1
        let gen = generation
        items = []
        selected = 0
        loading = true
        centeredPanel = false
        previousApp = NSWorkspace.shared.frontmostApplication

        let panel = self.panel ?? makePanel()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        render()

        // Light refresh so the "looking at" target tracks head movement while open.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        RunLoop.main.add(timer, forMode: .common)
        footerTimer = timer

        // Enumerate windows, then fill thumbnails progressively.
        Task { [weak self] in
            let list = await WindowMover.listWindows()
            guard let self, self.visible, gen == self.generation else { return }
            self.items = list
            self.loading = false
            self.render()
            await WindowMover.fillThumbnails(list) { [weak self] id, image in
                guard let self, self.visible, gen == self.generation else { return }
                if let i = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[i].image = image
                    self.render()
                }
            }
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        generation += 1
        footerTimer?.invalidate(); footerTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        coordinator.renderer?.clearPicker()
        panel?.orderOut(nil)
        previousApp?.activate()
        previousApp = nil
    }

    // MARK: Navigation

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.visible else { return event }
            switch event.keyCode {
            case 123: self.move(by: -1); return nil          // ←
            case 124: self.move(by: 1); return nil           // →
            case 126: self.move(by: -self.cols); return nil  // ↑
            case 125: self.move(by: self.cols); return nil   // ↓
            case 36, 76: self.commit(); return nil           // Return / Enter
            case 53: self.hide(); return nil                 // Esc
            default: return event
            }
        }
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        selected = min(max(0, selected + delta), items.count - 1)
        render()
    }

    private func commit() {
        guard !items.isEmpty else { hide(); return }
        let item = items[min(selected, items.count - 1)]
        switch coordinator.moveWindowToLookedAtScreen(item) {
        case .moved:
            previousApp = nil   // keep the moved window focused (don't restore the old app)
            hide()
        case .failed:
            hide()
        case .noTarget:
            render()            // keep open; the footer already prompts to look at a screen
        }
    }

    // MARK: Rendering

    private func render() {
        guard visible else { return }
        let count = items.count
        let sel = count == 0 ? 0 : min(max(0, selected), count - 1)
        let page = count == 0 ? 0 : sel / perPage
        let pageCount = count == 0 ? 1 : (count + perPage - 1) / perPage
        let pageItems = count == 0 ? []
            : Array(items[(page * perPage)..<min(count, page * perPage + perPage)])
        let view = WindowPickerContent(
            pageItems: pageItems, selectedInPage: sel - page * perPage,
            targetName: coordinator.lookedAtTargetName(),
            page: page, pageCount: pageCount, loading: loading)

        if coordinator.arActive, let renderer = coordinator.renderer,
           let image = rasterize(view), renderer.setPickerImage(image) {
            makePanelInvisible()              // panel stays key for input; visuals are the AR overlay
        } else {
            coordinator.renderer?.clearPicker()
            showPanel(view)
        }
    }

    private func rasterize(_ view: WindowPickerContent) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.cgImage
    }

    private func showPanel(_ view: WindowPickerContent) {
        guard let panel else { return }
        let hosting = self.hosting ?? NSHostingView(rootView: view)
        hosting.rootView = view
        self.hosting = hosting
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        if panel.contentView !== hosting { panel.contentView = hosting }
        panel.setContentSize(hosting.fittingSize)
        if !centeredPanel {
            panel.setFrameOrigin(WindowPlacement.originUnderCursor(
                size: panel.frame.size, excluding: coordinator.arOutputDisplayID))
            centeredPanel = true
        }
    }

    /// AR overlay path: keep the panel key (for input) but visually empty and off the glasses.
    private func makePanelInvisible() {
        guard let panel else { return }
        if !(panel.contentView is NSView) || panel.contentView is NSHostingView<WindowPickerContent> {
            panel.contentView = NSView()
        }
        if !centeredPanel {
            panel.setContentSize(NSSize(width: 2, height: 2))
            panel.setFrameOrigin(WindowPlacement.originUnderCursor(
                size: panel.frame.size, excluding: coordinator.arOutputDisplayID))
            centeredPanel = true
        }
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        return panel
    }
}

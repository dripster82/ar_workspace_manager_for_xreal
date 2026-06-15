import AppKit
import SwiftUI

/// A small floating prompt asking whether to restore the saved window layout. Shown on the Mac
/// screen under the cursor (never the glasses output), like the help panel. Enter restores,
/// Esc skips.
@MainActor
final class WindowRestorePromptController {
    private var panel: NSPanel?

    /// Present the prompt. `onChoice(true)` = restore, `onChoice(false)` = skip. Self-dismisses.
    func present(count: Int, excluding excludedDisplay: CGDirectDisplayID?,
                 onChoice: @escaping (Bool) -> Void) {
        dismiss()
        let finish: (Bool) -> Void = { [weak self] choice in
            self?.dismiss()
            onChoice(choice)
        }
        let view = WindowRestorePromptView(count: count,
                                           onRestore: { finish(true) },
                                           onSkip: { finish(false) })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let panel = NSPanel(contentRect: hosting.frame,
                            styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.setFrameOrigin(WindowPlacement.originUnderCursor(
            size: panel.frame.size, excluding: excludedDisplay))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct WindowRestorePromptView: View {
    let count: Int
    var onRestore: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 30)).foregroundStyle(.tint)
            Text("Restore \(count) window\(count == 1 ? "" : "s")?")
                .font(.headline)
            Text("Put your apps back on the screens and positions they had last time.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Skip") { onSkip() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore") { onRestore() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 320)
    }
}

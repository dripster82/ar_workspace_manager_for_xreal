import SwiftUI

/// Single source of truth for the app's shortcuts, shown by the help overlay.
enum HelpContent {
    struct Shortcut: Identifiable {
        let id = UUID()
        let keys: String
        let action: String
    }
    struct Section: Identifiable {
        let id = UUID()
        let title: String
        let column: Int  // 0 = left column, 1 = right column
        let shortcuts: [Shortcut]
    }

    static let sections: [Section] = [
        Section(
            title: "AR & view", column: 0,
            shortcuts: [
                Shortcut(keys: "⌃⌥S", action: "Start / stop AR"),
                Shortcut(keys: "⌃⌥Esc", action: "Stop AR"),
                Shortcut(keys: "⌃⌥Space", action: "Recenter the view"),
                Shortcut(keys: "⌃⌥B", action: "Recalibrate drift (hold still ~15s)"),
                Shortcut(keys: "⌃⌥D", action: "Depth — Stereo (SBS) on / off"),
                Shortcut(keys: "⌃⌥F", action: "Focus the screen you're looking at (toggle)"),
                Shortcut(keys: "⌃⌥V", action: "Passthrough — hide / show the screens (HUD stays)"),
                Shortcut(keys: "⌃⌥W", action: "Move a window to the screen you're looking at"),
            ]),
        Section(
            title: "Cursor", column: 0,
            shortcuts: [
                Shortcut(keys: "⌃⌥C", action: "Find the cursor (screen + arrow)"),
                Shortcut(keys: "⌃⌥X", action: "Move cursor to where you're looking"),
            ]),
        Section(
            title: "Capture", column: 1,
            shortcuts: [
                Shortcut(keys: "⌃⌥P", action: "Screenshot the glasses view → Desktop"),
                Shortcut(keys: "⌃⌥R", action: "Record the glasses view → Movies"),
                Shortcut(keys: "⌃⌥M", action: "Mute / unmute the recording mic"),
            ]),
        Section(
            title: "Display & HUD", column: 1,
            shortcuts: [
                Shortcut(keys: "⌃⌥ + brightness", action: "Dim / brighten the glasses"),
                Shortcut(keys: "⌃⌥I", action: "Show / hide the HUD widgets"),
                Shortcut(keys: "⌃⌥L", action: "Show / hide screen name labels"),
            ]),
        Section(
            title: "Media player", column: 1,
            shortcuts: [
                Shortcut(keys: "⌃⌥1–4", action: "Pin the video to a corner (TL · TR · BL · BR)"),
                Shortcut(keys: "⌃⌥5", action: "Video full view"),
                Shortcut(keys: "⌃⌥K", action: "Play / pause"),
                Shortcut(keys: "⌃⌥← ⌃⌥→", action: "Rewind / skip 10 s"),
                Shortcut(keys: "⌃⌥0", action: "Stop (keeps the playlist)"),
            ]),
        Section(
            title: "App", column: 1,
            shortcuts: [
                Shortcut(keys: "⌃⌥H", action: "Show / hide this help"),
                Shortcut(keys: "⌃⌥Q", action: "Quit AR Workspace Manager"),
            ]),
    ]

    /// Sections grouped by their target column (for the two-column layout).
    static func sections(inColumn column: Int) -> [Section] {
        sections.filter { $0.column == column }
    }

    /// Render the help panel to a CGImage (transparent outside the rounded card) for the
    /// in-AR overlay texture. Main-actor because it rasterizes SwiftUI.
    @MainActor
    static func renderCGImage(scale: CGFloat = 2) -> CGImage? {
        let renderer = ImageRenderer(content: HelpView())
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }
}

/// The help card, used both for the in-AR overlay rasterization and the macOS fallback panel.
struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("AR Workspace Manager — Shortcuts", systemImage: "keyboard")
                .font(.headline)
            HStack(alignment: .top, spacing: 28) {
                column(0)
                column(1)
            }
            Text("Press ⌃⌥H to close")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 640, alignment: .leading)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15)))
        .foregroundStyle(.white)
    }

    private func column(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(HelpContent.sections(inColumn: index)) { section in
                sectionView(section)
            }
        }
        .frame(width: 270, alignment: .leading)
    }

    private func sectionView(_ section: HelpContent.Section) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(section.title)
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(section.shortcuts) { sc in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(sc.keys)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        .frame(width: 120, alignment: .leading)
                    Text(sc.action).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

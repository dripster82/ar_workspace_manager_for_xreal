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
        let shortcuts: [Shortcut]
    }

    static let sections: [Section] = [
        Section(title: "Global hotkeys", shortcuts: [
            Shortcut(keys: "⌃⌥S", action: "Start / stop AR"),
            Shortcut(keys: "⌃⌥Esc", action: "Stop AR"),
            Shortcut(keys: "⌃⌥Space", action: "Recenter the view"),
            Shortcut(keys: "⌃⌥D", action: "Depth — Stereo (SBS) on / off"),
            Shortcut(keys: "⌃⌥ + brightness", action: "Dim / brighten the glasses"),
            Shortcut(keys: "⌃⌥H", action: "Show / hide this help"),
            Shortcut(keys: "⌃⌥C", action: "Find the cursor (looking-at / cursor screen + arrow)"),
            Shortcut(keys: "⌃⌥X", action: "Move cursor to where you're looking"),
            Shortcut(keys: "⌃⌥P", action: "Screenshot the glasses view → Desktop"),
            Shortcut(keys: "⌃⌥R", action: "Record the glasses view → Movies"),
            Shortcut(keys: "⌃⌥M", action: "Mute / unmute the recording mic"),
            Shortcut(keys: "⌃⌥I", action: "Show / hide the HUD widgets"),
            Shortcut(keys: "⌃⌥Q", action: "Quit VR Desktop"),
        ]),
    ]

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
            Label("VR Desktop — Shortcuts", systemImage: "keyboard")
                .font(.headline)
            ForEach(HelpContent.sections) { section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title)
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(section.shortcuts) { sc in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(sc.keys)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                                .frame(width: 150, alignment: .leading)
                            Text(sc.action).font(.callout)
                        }
                    }
                }
            }
            Text("Press ⌃⌥H to close")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 460, alignment: .leading)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15)))
        .foregroundStyle(.white)
    }
}

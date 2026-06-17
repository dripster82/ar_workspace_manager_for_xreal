import AppKit
import SwiftUI

/// Where the user's gaze (head-forward ray — no eye tracking) lands in the glasses: which
/// AR screen and the pixel on it. Computed on demand when the popup opens.
struct GazeReadout {
    let screenName: String
    let pixel: CGPoint
    let screenSize: CGSize
    let offScreen: Bool   // gaze hit the screen's plane but outside its bounds (clamped)
}

/// A snapshot of where the mouse cursor is right now: which screen it's on and its
/// coordinates (both global desktop-space and local to that screen). Captured at the
/// moment ⌃⌥C is pressed — handy for "where did my cursor go?" across many virtual screens.
struct CursorInfo {
    let screenName: String
    let displayID: CGDirectDisplayID
    let isARorGlasses: Bool
    let global: CGPoint          // desktop space, top-left origin (matches what users expect)
    let local: CGPoint           // relative to the screen's top-left corner
    let screenSize: CGSize

    /// Gather the current cursor position and resolve the screen under it.
    @MainActor
    static func current(arOutputDisplayID: CGDirectDisplayID?) -> CursorInfo {
        // NSEvent.mouseLocation: global, bottom-left origin (AppKit convention).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        let displayID = screen.map(AppCoordinator.screenDisplayID) ?? 0

        // Convert to a top-left origin within the whole desktop, using the primary screen's
        // height (the global coordinate space is anchored to the main display).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let globalTopLeft = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)

        // Local to this screen, top-left origin.
        let localX = mouse.x - frame.minX
        let localYBottom = mouse.y - frame.minY
        let localTopLeft = CGPoint(x: localX, y: frame.height - localYBottom)

        return CursorInfo(
            screenName: screen?.localizedName ?? "Display \(displayID)",
            displayID: displayID,
            isARorGlasses: arOutputDisplayID != nil && displayID == arOutputDisplayID,
            global: globalTopLeft,
            local: localTopLeft,
            screenSize: frame.size)
    }

    /// Render the popup card to a CGImage (transparent outside the card) for the in-AR overlay.
    @MainActor
    func renderCGImage(gaze: GazeReadout?, scale: CGFloat = 2) -> CGImage? {
        let renderer = ImageRenderer(content: CursorInfoView(info: self, gaze: gaze))
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }
}

/// The cursor-info card, used both for the in-AR overlay rasterization and the macOS panel.
/// Shows the mouse cursor's location plus, when AR is running, where the gaze lands in-glasses.
struct CursorInfoView: View {
    let info: CursorInfo
    let gaze: GazeReadout?

    private func fmt(_ p: CGPoint) -> String {
        String(format: "%.0f, %.0f", p.x, p.y)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Cursor", systemImage: "cursorarrow.rays")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                row("Screen", info.screenName + (info.isARorGlasses ? "  (AR output)" : ""))
                row("Display ID", "\(info.displayID)")
                row("Position", fmt(info.global))
                row("On screen", "\(fmt(info.local))  of  "
                    + String(format: "%.0f × %.0f", info.screenSize.width, info.screenSize.height))
            }

            Divider().overlay(.white.opacity(0.15))

            Label("Looking at", systemImage: "eye")
                .font(.headline)
            if let gaze {
                VStack(alignment: .leading, spacing: 6) {
                    row("Screen", gaze.screenName)
                    row("Gaze", fmt(gaze.pixel) + (gaze.offScreen ? "  (edge)" : ""))
                    row("On screen", String(format: "%.0f × %.0f",
                                            gaze.screenSize.width, gaze.screenSize.height))
                }
            } else {
                Text("Not looking at a screen (or AR is off).")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Text("Press ⌃⌥C to refresh / close")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 380, alignment: .leading)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15)))
        .foregroundStyle(.white)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

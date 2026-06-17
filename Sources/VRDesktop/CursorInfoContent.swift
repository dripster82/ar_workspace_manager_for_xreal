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

/// The direction from the eye to the mouse cursor's position in AR space, expressed relative
/// to where the head is currently pointing — i.e. which way to turn to bring the cursor to
/// centre. Used to draw a pointing arrow in the popup.
struct CursorDirection {
    let azimuthDeg: Double      // + = cursor is to the right
    let elevationDeg: Double    // + = cursor is above
    let angleRadians: Double    // arrow rotation, clockwise from straight up
    let centered: Bool          // cursor is ~dead ahead

    /// "24° right · 8° up" style summary.
    var summary: String {
        if centered { return "dead ahead" }
        let h = abs(azimuthDeg) < 1 ? nil
            : String(format: "%.0f° %@", abs(azimuthDeg), azimuthDeg >= 0 ? "right" : "left")
        let vrt = abs(elevationDeg) < 1 ? nil
            : String(format: "%.0f° %@", abs(elevationDeg), elevationDeg >= 0 ? "up" : "down")
        return [h, vrt].compactMap { $0 }.joined(separator: " · ")
    }
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
    func renderCGImage(gaze: GazeReadout?, direction: CursorDirection?, scale: CGFloat = 2) -> CGImage? {
        let renderer = ImageRenderer(content: CursorInfoView(info: self, gaze: gaze, direction: direction))
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
    let direction: CursorDirection?

    private func fmt(_ p: CGPoint) -> String {
        String(format: "%.0f, %.0f", p.x, p.y)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("Cursor", systemImage: "cursorarrow.rays")
                    .font(.headline)
                Spacer()
                if let direction { directionArrow(direction) }
            }
            VStack(alignment: .leading, spacing: 6) {
                row("Screen", info.screenName + (info.isARorGlasses ? "  (AR output)" : ""))
                row("Display ID", "\(info.displayID)")
                row("Position", fmt(info.global))
                row("On screen", "\(fmt(info.local))  of  "
                    + String(format: "%.0f × %.0f", info.screenSize.width, info.screenSize.height))
                if let direction { row("Direction", direction.summary) }
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

    /// A compass-style arrow pointing the way to turn the head to reach the cursor. When the
    /// cursor is already dead ahead it shows a target dot instead.
    @ViewBuilder
    private func directionArrow(_ d: CursorDirection) -> some View {
        ZStack {
            Circle().fill(.white.opacity(0.10))
            Circle().strokeBorder(.white.opacity(0.18))
            if d.centered {
                Image(systemName: "scope").font(.system(size: 16, weight: .semibold))
            } else {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold))
                    .rotationEffect(.radians(d.angleRadians))
            }
        }
        .frame(width: 34, height: 34)
        .foregroundStyle(.tint)
        .help("Direction to turn to bring the cursor to centre: \(d.summary)")
    }
}

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
/// A compact readout: which screen you're looking at, which screen the cursor is on, and an
/// arrow pointing the way to turn to find the cursor. Auto-refreshes while visible.
struct CursorInfoView: View {
    let info: CursorInfo
    let gaze: GazeReadout?
    let direction: CursorDirection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            line("You are looking at:", gaze?.screenName ?? "—")
            line("The cursor is on:", info.screenName)
            HStack { Spacer(); directionArrow(direction); Spacer() }
        }
        .padding(24)
        .frame(width: 300, alignment: .leading)
        .background(Color(white: 0.34).opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.22)))
        .foregroundStyle(.white)
    }

    private func line(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).lineLimit(1)
        }
    }

    /// A compass-style arrow pointing the way to turn the head to reach the cursor. Shows a target
    /// reticle when the cursor is dead ahead, or a dimmed dot when there's no direction (AR off /
    /// cursor not on an AR screen).
    @ViewBuilder
    private func directionArrow(_ d: CursorDirection?) -> some View {
        ZStack {
            Circle().fill(.white.opacity(0.10))
            Circle().strokeBorder(.white.opacity(0.18))
            if let d {
                if d.centered {
                    Image(systemName: "scope").font(.system(size: 22, weight: .semibold))
                } else {
                    Image(systemName: "arrow.up").font(.system(size: 26, weight: .bold))
                        .rotationEffect(.radians(d.angleRadians))
                }
            } else {
                Circle().fill(.white.opacity(0.25)).frame(width: 6, height: 6)
            }
        }
        .frame(width: 52, height: 52)
        .foregroundStyle(.tint)
        .help(d.map { "Turn to bring the cursor to centre: \($0.summary)" }
              ?? "Cursor direction unavailable (AR off or cursor not on an AR screen)")
    }
}

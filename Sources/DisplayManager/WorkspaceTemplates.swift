import Foundation

/// Curated multi-screen workspace presets, sized and placed for the XREAL One / One Pro field of
/// view (≈40° × 23° usable per eye, 1920×1080) so 1080p content stays genuinely readable — never
/// crammed. Geometry validated against the renderer's sizing math: every screen lands at a pixel
/// density of ~1.5–2.4 arcmin/px at its distance. Each call builds a fresh `Workspace` with brand
/// new screen UUIDs.
public enum WorkspaceTemplate: String, CaseIterable, Identifiable, Sendable {
    case singleFocus
    case fourSquare
    case tripleCurved
    case stackedDuo
    case devCockpit
    case theater
    case surround360
    case surroundWall
    case wraparoundUltrawide

    public var id: String { rawValue }

    /// Menu title.
    public var title: String {
        switch self {
        case .singleFocus:  return "Single Focus"
        case .fourSquare:   return "4 Screens — Square"
        case .tripleCurved: return "Triple Curved"
        case .stackedDuo:   return "Stacked Duo"
        case .devCockpit:   return "Dev Cockpit"
        case .theater:      return "Theater"
        case .surround360:  return "360° Surround"
        case .surroundWall: return "Surround Wall"
        case .wraparoundUltrawide: return "Wraparound Ultrawide"
        }
    }

    /// One-line description.
    public var subtitle: String {
        switch self {
        case .singleFocus:  return "One big screen at the readable sweet spot"
        case .fourSquare:   return "2×2 grid in front, gently curved"
        case .tripleCurved: return "Three screens wrapped in a front arc"
        case .stackedDuo:   return "Two screens stacked vertically"
        case .devCockpit:   return "Big center + two side panels"
        case .theater:      return "One large distant 16:9, for media"
        case .surround360:  return "Seven screens encircling you"
        case .surroundWall: return "Eight 1080p screens joined into a full ring"
        case .wraparoundUltrawide: return "One 32:9 desktop curved all around you"
        }
    }

    /// Build a fresh workspace for this template (new UUIDs throughout).
    public func makeWorkspace() -> Workspace {
        Workspace(name: title, virtualScreens: screens())
    }

    /// A 1080p tile, curved toward the viewer by default (`autoCurveH`). Keeps the layout tables terse.
    private func tile(_ name: String, yaw: Double, pitch: Double = 0, dist: Double, scale: Double,
                      curved: Bool = true, placement: ScreenPlacement = .anchored,
                      hiDPI: Bool = true, w: Int = 1920, h: Int = 1080) -> VirtualScreenConfig {
        VirtualScreenConfig(name: name, width: w, height: h, hiDPI: hiDPI,
                            yawDegrees: yaw, pitchDegrees: pitch, distanceMeters: dist,
                            scale: scale, curvatureRadius: 0, autoCurveH: curved,
                            placement: placement)
    }

    private func screens() -> [VirtualScreenConfig] {
        switch self {
        case .singleFocus:
            // Head-locked so it stays centred and fills the view (mirrors the app's focus mode).
            return [tile("Focus", yaw: 0, dist: 1.2, scale: 1.0, placement: .floating)]

        case .fourSquare:
            // scale 0.62 @ 1.4 m → ~39° wide × ~22° tall; ±20° yaw / ±12° pitch spacing leaves a
            // small gap between tiles (NOT the overlap the earlier 0.85/±15° values produced — the
            // 2D layout map can't show angular size, so overlap only appears in the headset).
            return [
                tile("Top-Left",     yaw: -20, pitch:  12, dist: 1.4, scale: 0.62),
                tile("Top-Right",    yaw:  20, pitch:  12, dist: 1.4, scale: 0.62),
                tile("Bottom-Left",  yaw: -20, pitch: -12, dist: 1.4, scale: 0.62),
                tile("Bottom-Right", yaw:  20, pitch: -12, dist: 1.4, scale: 0.62),
            ]

        case .tripleCurved:
            // ±48° butts the ~49°-wide screens edge-to-edge into one ~146° curved wall.
            return [
                tile("Center", yaw:   0, dist: 1.5, scale: 0.85),
                tile("Left",   yaw: -48, dist: 1.5, scale: 0.85),
                tile("Right",  yaw:  48, dist: 1.5, scale: 0.85),
            ]

        case .stackedDuo:
            // ±18° pitch stacks the ~32°-tall screens edge-to-edge vertically (seam at eye level).
            return [
                tile("Top",    yaw: 0, pitch:  18, dist: 1.4, scale: 0.90),
                tile("Bottom", yaw: 0, pitch: -18, dist: 1.4, scale: 0.90),
            ]

        case .devCockpit:
            // Bigger, closer Main dominates; smaller side panels pushed to ±42° + nudged up so their
            // inner edges clear Main.
            // Main ~59° wide (±29.7°); sides ~46° wide must sit beyond ±53° so their inner edges
            // clear Main. ±54° leaves a small gap (±42° overlapped Main by ~11° in the headset).
            return [
                tile("Main",  yaw:   0, pitch: 0, dist: 1.4, scale: 1.00),
                tile("Left",  yaw: -54, pitch: 2, dist: 1.5, scale: 0.80),
                tile("Right", yaw:  54, pitch: 2, dist: 1.5, scale: 0.80),
            ]

        case .theater:
            // Far, large, flat 16:9 — a fixed "wall" you sit back from. Tuned for video/slides.
            return [tile("Screen", yaw: 0, pitch: -3, dist: 3.5, scale: 1.9, curved: false, hiDPI: false)]

        case .surround360:
            // Seven screens, 360/7 ≈ 51.43° apart, at eye height — a swivel-chair ring.
            let step = 360.0 / 7.0
            return (0..<7).map { i in
                let raw = Double(i) * step
                let yaw = raw > 180 ? raw - 360 : raw   // map to (−180, 180]
                return tile(i == 0 ? "Front" : "Screen \(i + 1)", yaw: yaw, dist: 1.5, scale: 0.80)
            }

        case .surroundWall:
            // Eight 1080p screens butted edge-to-edge into one continuous 360° ring. Each spans
            // exactly 45° (scale 0.74 @ 1.5m) and autoCurveH bends it onto the shared eye-centred
            // cylinder, so adjacent edges meet seamlessly. hiDPI off — 8 live captures is already
            // demanding, and at 45°/1080p you're at ~43 px/° (the glasses can't resolve much more).
            let n = 8
            let step = 360.0 / Double(n)
            return (0..<n).map { i in
                let raw = Double(i) * step
                let yaw = raw > 180 ? raw - 360 : raw
                return tile("Wall \(i + 1)", yaw: yaw, dist: 1.5, scale: 0.74, hiDPI: false)
            }

        case .wraparoundUltrawide:
            // One single 32:9 desktop (5120×1440, the max single-display width) bent onto an
            // eye-centred cylinder. autoCurveH arc = widthMeters/distance; scale 1.3 @ 2.0 m gives a
            // ~160° immersive curve in front of and beside you — readable (~32 px/°) and not in your
            // face. A *full* 360° single desktop only ever shows a tiny sliver at once (you'd see
            // almost nothing), which is why this is a deep curve, not a full wrap. For all-the-way-
            // around, use "Surround Wall".
            return [tile("Panorama", yaw: 0, dist: 2.0, scale: 1.3, hiDPI: false, w: 5120, h: 1440)]
        }
    }
}

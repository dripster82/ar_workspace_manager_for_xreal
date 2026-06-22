import CoreGraphics
import Foundation
import Metal
import simd

/// One source image composited into a region of a wide-canvas atlas texture.
/// Destination coordinates are in atlas pixels from the top-left.
public struct CanvasTile {
    public let sourceProvider: () -> MTLTexture?
    public let destX: Int
    public let destY: Int
    public let destWidth: Int
    public let destHeight: Int
    public init(sourceProvider: @escaping () -> MTLTexture?,
                destX: Int, destY: Int, destWidth: Int, destHeight: Int) {
        self.sourceProvider = sourceProvider
        self.destX = destX
        self.destY = destY
        self.destWidth = destWidth
        self.destHeight = destHeight
    }
}

/// One screen placed in the AR scene, centred at (yaw, pitch) and bent onto a
/// (optionally doubly-)curved surface in front of the viewer.
public struct SceneScreen: Identifiable {
    public let id: UUID
    public var yaw: Float           // radians, negative = left
    public var pitch: Float         // radians
    public var distance: Float      // meters
    public var widthMeters: Float   // apparent width at `distance`
    public var aspect: Float        // width / height of content
    public var curveH: Float        // horizontal curve amount, 0 = flat
    /// When set, the screen curves to follow the natural sphere around the eye
    /// (radius = distance), so the surface is equidistant and matches the space.
    public var autoCurveH: Bool
    /// Head-locked: render without head rotation so it stays fixed in the field of view.
    public var headLocked: Bool
    /// When true, the screen is a segment of one shared cylinder centred on the eye (yaw is
    /// baked into the arc angle), so several screens at the same distance tile into a single
    /// continuous curved surface instead of each curving around its own centre.
    public var cylindrical: Bool
    public var textureProvider: () -> MTLTexture?

    /// Wide-canvas atlas: when `canvasTiles` is non-empty this screen is a single merged
    /// surface. The renderer composites each tile's live source into one atlas texture of
    /// `canvasPixelWidth × canvasPixelHeight`, then samples that atlas across this one
    /// curved mesh — so the whole canvas bends as a single image with no per-screen gaps.
    public var canvasPixelWidth: Int = 0
    public var canvasPixelHeight: Int = 0
    public var canvasTiles: [CanvasTile] = []
    public var isCanvas: Bool { !canvasTiles.isEmpty }

    /// Optional corner label (the screen's name), shown top-left when labels are toggled on (⌃⌥L).
    /// The renderer rasterises `labelImage` to a texture (cached by `labelText`) and places it with
    /// `labelQuad`. Left nil for merged canvas screens.
    public var labelText: String?
    public var labelImage: CGImage?

    public init(id: UUID, yaw: Float, pitch: Float, distance: Float, widthMeters: Float,
                aspect: Float, curveH: Float, autoCurveH: Bool, headLocked: Bool = false,
                cylindrical: Bool = false,
                textureProvider: @escaping () -> MTLTexture?) {
        self.id = id
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.widthMeters = widthMeters
        self.aspect = aspect
        self.curveH = max(0, min(5, curveH))
        self.autoCurveH = autoCurveH
        self.headLocked = headLocked
        self.cylindrical = cylindrical
        self.textureProvider = textureProvider
    }

    /// Build a wide-canvas merged surface: one horizontally-curved, vertically-flat mesh
    /// centred at (yaw, pitch) that samples a composited atlas of the given pixel size.
    public init(canvasID: UUID, yaw: Float, pitch: Float, distance: Float, widthMeters: Float,
                aspect: Float, canvasPixelWidth: Int, canvasPixelHeight: Int, tiles: [CanvasTile]) {
        self.id = canvasID
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.widthMeters = widthMeters
        self.aspect = aspect
        self.curveH = 0
        self.autoCurveH = true       // follow the natural sphere arc horizontally
        self.headLocked = false
        self.cylindrical = false
        self.canvasPixelWidth = canvasPixelWidth
        self.canvasPixelHeight = canvasPixelHeight
        self.canvasTiles = tiles
        self.textureProvider = { nil }   // the renderer supplies the atlas instead
    }

    struct Vertex {
        var position: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    /// Arc (radians) per unit of manual curve amount; amount 5 ≈ 150° wrap.
    private static let arcPerUnit: Float = 30 * .pi / 180

    private var height: Float { widthMeters / aspect }

    /// Total horizontal / vertical subtended angles (radians).
    private var angles: (x: Float, y: Float) {
        // Horizontal curve only: auto = natural sphere arc (width / distance, so closer
        // screens curve more); manual = curve amount × arc-per-unit. Vertical stays flat.
        // Cylindrical (unified canvas) always follows the natural arc on the shared cylinder.
        let x = (cylindrical || autoCurveH) ? widthMeters / distance : curveH * Self.arcPerUnit
        return (x, 0)
    }

    func vertices() -> [Vertex] {
        let (thetaX, thetaY) = angles
        let segX = thetaX > 0.001 ? max(8, Int(widthMeters * 16)) : 1
        // The wide canvas keeps a flat vertical surface but places each row at its true elevation
        // angle (see `point`), so it needs several vertical segments to follow that tan spacing.
        let segY = thetaY > 0.001 ? max(6, Int(height * 16)) : (isCanvas ? max(8, Int(height * 8)) : 1)

        var verts: [Vertex] = []
        verts.reserveCapacity(segX * segY * 6)
        for ix in 0..<segX {
            let u0 = Float(ix) / Float(segX), u1 = Float(ix + 1) / Float(segX)
            for iy in 0..<segY {
                let v0 = Float(iy) / Float(segY), v1 = Float(iy + 1) / Float(segY)
                let p00 = point(u: u0, v: v0, thetaX: thetaX, thetaY: thetaY)
                let p10 = point(u: u1, v: v0, thetaX: thetaX, thetaY: thetaY)
                let p01 = point(u: u0, v: v1, thetaX: thetaX, thetaY: thetaY)
                let p11 = point(u: u1, v: v1, thetaX: thetaX, thetaY: thetaY)
                verts.append(Vertex(position: p00, uv: SIMD2(u0, v0)))
                verts.append(Vertex(position: p10, uv: SIMD2(u1, v0)))
                verts.append(Vertex(position: p01, uv: SIMD2(u0, v1)))
                verts.append(Vertex(position: p10, uv: SIMD2(u1, v0)))
                verts.append(Vertex(position: p11, uv: SIMD2(u1, v1)))
                verts.append(Vertex(position: p01, uv: SIMD2(u0, v1)))
            }
        }
        return verts
    }

    /// Surface point at (u, v) ∈ [0,1] (v: top→bottom). Each axis is bent onto a
    /// cylinder whose arc length equals the screen's width/height (so curving never
    /// resizes the screen); the two bends compose into a doubly-curved patch that,
    /// when thetaX == thetaY, approximates the natural sphere around the eye.
    private func point(u: Float, v: Float, thetaX: Float, thetaY: Float) -> SIMD3<Float> {
        // Wide canvas: a section of a sphere of radius `distance` centred on the eye. Each pixel
        // maps to its ABSOLUTE azimuth/elevation (φ = 0, θ = 0 is straight ahead — the FOV
        // centre), so the whole canvas curves around the viewer's forward direction rather than
        // around its own image centre. `yaw`/`pitch` carry the canvas centre direction, and
        // width/height ÷ distance are the total azimuth/elevation arcs.
        if isCanvas {
            let R = distance
            let arcX = widthMeters / distance
            let arcY = height / distance
            let phi = -yaw + (u - 0.5) * arcX        // absolute azimuth, 0 = FOV forward
            let theta = pitch + (0.5 - v) * arcY     // absolute elevation, 0 = FOV forward
            // Horizontal wraps on an eye-centred cylinder (vertical axis through the eye), so the
            // curve is referenced to the FOV centre. Vertical stays a straight column with natural
            // perspective: y = R·tan(elevation) keeps each row at its true angle while letting
            // top/bottom recede — so the vertical curve is actually visible in the mono render.
            return SIMD3(R * sinf(phi), R * tanf(theta), -R * cosf(phi))
        }

        // Unified cylinder: every screen lies on one cylinder of radius `distance` centred at
        // the eye, with yaw baked into the absolute arc angle, so adjacent screens form a
        // single continuous curve. Vertical stays flat; pitch tilts the segment.
        if cylindrical {
            let R = distance
            // Absolute angle on the shared cylinder. Matches the non-cylindrical path's
            // effective angle (arc − yaw from the +Y rotation), so left/right isn't mirrored.
            let phi = (u - 0.5) * thetaX - yaw
            let yLocal = (0.5 - v) * height
            let local = SIMD3(R * sinf(phi), yLocal, -R * cosf(phi))
            return simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)).act(local)
        }

        var x: Float, y: Float
        var zDev: Float = 0 // forward deviation from the flat plane at -distance

        if thetaX > 0.001 {
            let rX = widthMeters / thetaX
            let ax = (u - 0.5) * thetaX
            x = sinf(ax) * rX
            zDev += rX * (1 - cosf(ax))
        } else {
            x = (u - 0.5) * widthMeters
        }

        if thetaY > 0.001 {
            let rY = height / thetaY
            let ay = (0.5 - v) * thetaY
            y = sinf(ay) * rY
            zDev += rY * (1 - cosf(ay))
        } else {
            y = (0.5 - v) * height
        }

        let local = SIMD3(x, y, -distance + zDev)
        let qYaw = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let qPitch = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        return qYaw.act(qPitch.act(local))
    }

    /// World-space quad (6 vertices, 2 triangles) for a top-left corner label sized to the given
    /// image aspect, anchored just inside the screen's top-left and lying in the screen's plane.
    /// Returns nil for merged canvas screens (a per-screen label doesn't map to one merged surface).
    func labelQuad(imageAspect aspect: Float) -> [Vertex]? {
        guard !isCanvas else { return nil }
        let (thetaX, thetaY) = angles
        let corner = point(u: 0, v: 0, thetaX: thetaX, thetaY: thetaY) // exact top-left
        // Orient the label using the screen's placement rotation (exact for flat screens; a close
        // approximation near the corner of curved ones).
        let rot = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        let right = rot.act(SIMD3<Float>(1, 0, 0))
        let up = rot.act(SIMD3<Float>(0, 1, 0))
        let lh = max(0.05, height * 0.09)          // label height: ~9% of the screen height
        let lw = lh * aspect
        let inset = lh * 0.35                        // nudge inside the corner so it sits on-screen
        let tl = corner + right * inset - up * inset
        let p00 = tl, p10 = tl + right * lw
        let p01 = tl - up * lh, p11 = tl + right * lw - up * lh
        return [
            Vertex(position: p00, uv: SIMD2(0, 0)),
            Vertex(position: p10, uv: SIMD2(1, 0)),
            Vertex(position: p01, uv: SIMD2(0, 1)),
            Vertex(position: p10, uv: SIMD2(1, 0)),
            Vertex(position: p11, uv: SIMD2(1, 1)),
            Vertex(position: p01, uv: SIMD2(0, 1)),
        ]
    }
}

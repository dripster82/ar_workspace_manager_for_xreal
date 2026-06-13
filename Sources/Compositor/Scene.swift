import Foundation
import Metal
import simd

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
    public var curveV: Float        // vertical curve amount, 0 = flat
    /// When set, that axis curves to follow the natural sphere around the eye
    /// (radius = distance), so the surface is equidistant and matches the space.
    public var autoCurveH: Bool
    public var autoCurveV: Bool
    public var textureProvider: () -> MTLTexture?

    public init(id: UUID, yaw: Float, pitch: Float, distance: Float, widthMeters: Float,
                aspect: Float, curveH: Float, curveV: Float,
                autoCurveH: Bool, autoCurveV: Bool,
                textureProvider: @escaping () -> MTLTexture?) {
        self.id = id
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.widthMeters = widthMeters
        self.aspect = aspect
        self.curveH = max(0, min(5, curveH))
        self.curveV = max(0, min(5, curveV))
        self.autoCurveH = autoCurveH
        self.autoCurveV = autoCurveV
        self.textureProvider = textureProvider
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
        // Each axis independently: auto = natural sphere arc (size / distance, so closer
        // screens curve more); manual = curve amount × arc-per-unit.
        let x = autoCurveH ? widthMeters / distance : curveH * Self.arcPerUnit
        let y = autoCurveV ? height / distance : curveV * Self.arcPerUnit
        return (x, y)
    }

    func vertices() -> [Vertex] {
        let (thetaX, thetaY) = angles
        let segX = thetaX > 0.001 ? max(8, Int(widthMeters * 16)) : 1
        let segY = thetaY > 0.001 ? max(6, Int(height * 16)) : 1

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
}

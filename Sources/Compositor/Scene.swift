import Foundation
import Metal
import simd

/// One screen placed in the AR scene. Geometry is a flat or cylindrically curved
/// quad strip centred at (yaw, pitch) on a sphere of radius `distance`.
public struct SceneScreen: Identifiable {
    public let id: UUID
    public var yaw: Float           // radians, negative = left
    public var pitch: Float         // radians
    public var distance: Float      // meters
    public var widthMeters: Float   // apparent width at `distance`
    public var aspect: Float        // width / height of content
    public var curvatureRadius: Float // 0 = flat
    public var textureProvider: () -> MTLTexture?

    public init(id: UUID, yaw: Float, pitch: Float, distance: Float, widthMeters: Float,
                aspect: Float, curvatureRadius: Float, textureProvider: @escaping () -> MTLTexture?) {
        self.id = id
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.widthMeters = widthMeters
        self.aspect = aspect
        self.curvatureRadius = curvatureRadius
        self.textureProvider = textureProvider
    }

    struct Vertex {
        var position: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    /// Tessellate into a triangle list. Flat screens are a single quad; curved
    /// screens are segmented along the horizontal axis around the viewer.
    func vertices() -> [Vertex] {
        let height = widthMeters / aspect
        let segments = curvatureRadius > 0.01 ? max(8, Int(widthMeters * 16)) : 1
        var verts: [Vertex] = []
        verts.reserveCapacity(segments * 6)

        for i in 0..<segments {
            let t0 = Float(i) / Float(segments)
            let t1 = Float(i + 1) / Float(segments)
            let p00 = point(u: t0, v: 0, height: height)
            let p01 = point(u: t0, v: 1, height: height)
            let p10 = point(u: t1, v: 0, height: height)
            let p11 = point(u: t1, v: 1, height: height)
            // v=0 is top of screen (uv y grows downward in texture space)
            verts.append(Vertex(position: p00, uv: SIMD2(t0, 0)))
            verts.append(Vertex(position: p10, uv: SIMD2(t1, 0)))
            verts.append(Vertex(position: p01, uv: SIMD2(t0, 1)))
            verts.append(Vertex(position: p10, uv: SIMD2(t1, 0)))
            verts.append(Vertex(position: p11, uv: SIMD2(t1, 1)))
            verts.append(Vertex(position: p01, uv: SIMD2(t0, 1)))
        }
        return verts
    }

    /// Position of the surface point at horizontal param u ∈ [0,1], vertical v ∈ [0,1] (top→bottom).
    private func point(u: Float, v: Float, height: Float) -> SIMD3<Float> {
        let y = (0.5 - v) * height
        var local: SIMD3<Float>
        if curvatureRadius > 0.01 {
            // Wrap the screen width onto a cylinder of radius `curvatureRadius`
            // centred on the viewer, then push it out to `distance`.
            let arc = widthMeters / curvatureRadius
            let a = (u - 0.5) * arc
            let r = distance
            local = SIMD3(sinf(a) * r, y, -cosf(a) * r)
        } else {
            let x = (u - 0.5) * widthMeters
            local = SIMD3(x, y, -distance)
        }
        // Rotate into place by screen yaw/pitch.
        let qYaw = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let qPitch = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        return qYaw.act(qPitch.act(local))
    }
}

import simd
import Foundation

/// A 3DoF head pose sampled from the glasses' IMU.
public struct Pose: Sendable {
    public var orientation: simd_quatf
    public var angularVelocity: SIMD3<Float> // rad/s, device frame
    public var timestamp: TimeInterval       // host clock (CACurrentMediaTime base)

    public static let identity = Pose(
        orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        angularVelocity: .zero,
        timestamp: 0
    )

    public init(orientation: simd_quatf, angularVelocity: SIMD3<Float>, timestamp: TimeInterval) {
        self.orientation = orientation
        self.angularVelocity = angularVelocity
        self.timestamp = timestamp
    }

    /// Extrapolate the orientation `dt` seconds ahead using the last angular velocity.
    public func predicted(by dt: Float) -> simd_quatf {
        let w = angularVelocity
        let speed = simd_length(w)
        guard speed > 1e-5, dt > 0 else { return orientation }
        let delta = simd_quatf(angle: speed * dt, axis: w / speed)
        return simd_normalize(orientation * delta)
    }
}

/// Latest-value pose cell shared between the IMU thread (writer) and render thread (reader).
public final class PoseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pose: Pose = .identity
    private var referenceInverse = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var _sampleCount: UInt64 = 0

    public init() {}

    public func update(_ newPose: Pose) {
        lock.lock()
        pose = newPose
        _sampleCount &+= 1
        lock.unlock()
    }

    public func latest() -> Pose {
        lock.lock(); defer { lock.unlock() }
        var p = pose
        p.orientation = referenceInverse * p.orientation
        return p
    }

    public var sampleCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _sampleCount
    }

    /// Capture the current head orientation as the new "straight ahead".
    /// With `includeRoll` false, head tilt is excluded so the horizon stays gravity-level.
    public func recenter(includeRoll: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        var q = pose.orientation
        if !includeRoll {
            // Swing-twist decomposition: strip the twist about the local forward (Z)
            // axis — the roll — and recenter only the remaining swing (yaw + pitch).
            let projected = q.imag.z
            var twist = simd_quatf(ix: 0, iy: 0, iz: projected, r: q.real)
            let len = simd_length(twist.vector)
            if len > 1e-6 {
                twist = simd_quatf(vector: twist.vector / len)
                q = q * twist.inverse
            }
        }
        referenceInverse = q.inverse
    }
}

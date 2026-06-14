import simd
import Foundation

/// One-Euro filter for orientation: an adaptive low-pass whose cutoff rises with angular
/// speed. At rest it smooths hard (removing heartbeat/sensor jitter); during fast turns it
/// opens up so there's no perceptible lag. (Casiez, Roussel & Vogel, 2012.)
struct OneEuroOrientation {
    var minCutoff: Float = 1.0   // Hz — lower = calmer at rest
    var beta: Float = 0.5        // higher = more responsive to speed
    var dCutoff: Float = 1.0     // Hz — smoothing of the speed estimate

    private var initialized = false
    private var prevRaw = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var smoothed = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var speedLPF: Float = 0

    private func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func update(_ raw: simd_quatf, dt: Float) -> simd_quatf {
        guard dt > 0 else { return smoothed }
        if !initialized {
            initialized = true
            prevRaw = raw; smoothed = raw; speedLPF = 0
            return raw
        }
        // Take the shortest-path representation relative to the current estimate.
        var r = raw
        if simd_dot(r.vector, smoothed.vector) < 0 { r = simd_quatf(vector: -r.vector) }

        // Angular speed between consecutive raw samples, low-passed.
        var dq = r * prevRaw.inverse
        if dq.real < 0 { dq = simd_quatf(vector: -dq.vector) }
        let speed = (2 * acosf(min(1, dq.real))) / dt
        speedLPF += alpha(cutoff: dCutoff, dt: dt) * (speed - speedLPF)

        let cutoff = minCutoff + beta * speedLPF
        smoothed = simd_normalize(simd_slerp(smoothed, r, alpha(cutoff: cutoff, dt: dt)))
        prevRaw = r
        return smoothed
    }
}

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
    /// The extrapolation is clamped so a noisy velocity estimate can't throw the rendered
    /// frame ahead and snap it back: angular speed is capped at a physiological maximum and
    /// the total predicted rotation is capped at a few degrees.
    public func predicted(by dt: Float) -> simd_quatf {
        let w = angularVelocity
        let speed = simd_length(w)
        guard speed > 1e-5, dt > 0 else { return orientation }
        let maxSpeed: Float = 400 * .pi / 180   // ~400°/s — beyond this is sensor noise
        let maxAngle: Float = 5 * .pi / 180      // never extrapolate more than 5°
        let angle = min(min(speed, maxSpeed) * dt, maxAngle)
        let delta = simd_quatf(angle: angle, axis: w / speed)
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

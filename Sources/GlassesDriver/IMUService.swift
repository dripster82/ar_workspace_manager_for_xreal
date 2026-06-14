import CXrealDriver
import Foundation
import QuartzCore
import simd

/// Connection state of the glasses, published for the UI.
public enum GlassesState: Equatable, Sendable {
    case disconnected
    case connected(product: String)
    case error(String)
}

/// Owns the C driver and a dedicated thread running the ~1kHz HID read loop.
/// The C callback has no context pointer, so a single shared instance bridges to Swift.
public final class IMUService: @unchecked Sendable {
    public static let shared = IMUService()

    public let poseStore = PoseStore()
    public private(set) var state: GlassesState = .disconnected {
        didSet { stateChanged?(state) }
    }
    public var stateChanged: ((GlassesState) -> Void)?

    private var device = device_imu_type()
    private var thread: Thread?
    private var running = false
    private let queue = DispatchQueue(label: "imu.control")

    private init() {}

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let t = Thread { [self] in readLoop() }
            t.name = "IMU Read Loop"
            t.qualityOfService = .userInteractive
            t.start()
            thread = t
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
        }
    }

    public func recenter(includeRoll: Bool = true) { poseStore.recenter(includeRoll: includeRoll) }

    private func readLoop() {
        while running {
            var dev = device_imu_type()
            let err = device_imu_open(&dev, imuEventCallback)
            if err != DEVICE_IMU_ERROR_NO_ERROR {
                DispatchQueue.main.async { self.state = .disconnected }
                Thread.sleep(forTimeInterval: 2.0) // retry until plugged in
                continue
            }
            device = dev
            device_imu_clear(&device)
            let product = "XREAL (PID 0x\(String(device.product_id, radix: 16)))"
            DispatchQueue.main.async { self.state = .connected(product: product) }
            NSLog("IMUService: opened VID 0x%04x PID 0x%04x", device.vendor_id, device.product_id)

            while running {
                let r = device_imu_read(&device, 100) // ms timeout
                if r == DEVICE_IMU_ERROR_UNPLUGGED || r == DEVICE_IMU_ERROR_NO_DEVICE || r == DEVICE_IMU_ERROR_NO_HANDLE {
                    break
                }
            }
            device_imu_close(&device)
            DispatchQueue.main.async { self.state = .disconnected }
        }
    }

    fileprivate func handleUpdate(_ ahrs: OpaquePointer?) {
        guard let ahrs else { return }
        let q = device_imu_get_orientation(ahrs)
        // Driver axes are a cyclic permutation of the render world's (x=pitch, y=yaw, z=roll):
        // driver y carries pitch, z carries yaw, x carries roll. Remap (x,y,z) → (y,z,x),
        // with yaw and roll negated (driver's frame is mirrored on those axes vs. the render world).
        let raw = simd_normalize(simd_quatf(ix: q.y, iy: -q.z, iz: -q.x, r: q.w))
        let now = CACurrentMediaTime()

        // Estimate instantaneous angular velocity from successive raw orientations.
        let prev = lastSample
        var instAngVel = SIMD3<Float>.zero
        if let prev, now > prev.t {
            let dq = raw * prev.q.inverse
            let angle = 2 * acosf(min(1, abs(dq.real)))
            if angle > 1e-5 {
                let s = sqrtf(max(1e-10, 1 - dq.real * dq.real))
                let axis = SIMD3(dq.imag.x / s, dq.imag.y / s, dq.imag.z / s)
                instAngVel = axis * (angle / Float(now - prev.t)) * (dq.real < 0 ? -1 : 1)
            }
        }
        lastSample = (raw, now)
        let dt = Float(prev.map { now - $0.t } ?? 0.001)

        // Orientation: One-Euro adaptive filter — heavy smoothing when nearly still (kills
        // heartbeat/sensor jitter), little smoothing when turning (no perceptible lag).
        orientationFilter.minCutoff = minCutoff
        orientationFilter.beta = beta
        let qSmooth = orientationFilter.update(raw, dt: dt)

        // Angular velocity for prediction: a plain low-pass is fine here.
        let velocityAlpha = 1 - expf(-dt / velocityTimeConstant)
        velFiltered += (instAngVel - velFiltered) * velocityAlpha

        poseStore.update(Pose(orientation: qSmooth, angularVelocity: velFiltered, timestamp: now))

        // Raw/filtered diagnostics for head-movement testing (throttled to ~60 Hz).
        if rawLoggingEnabled, let rawLog, now - lastRawLog >= 0.016 {
            lastRawLog = now
            let r = Self.eulerDeg(raw), f = Self.eulerDeg(qSmooth)
            let speed = simd_length(instAngVel) * 180 / .pi
            rawLog(String(format:
                "imu raw[y%+7.2f p%+7.2f r%+7.2f] filt[y%+7.2f p%+7.2f r%+7.2f] w=%6.1f°/s dt=%4.1fms",
                r.y, r.p, r.r, f.y, f.p, f.r, speed, dt * 1000))
        }
    }

    /// One-Euro parameters (set from the UI). Lower minCutoff = calmer at rest;
    /// higher beta = more responsive to fast head turns (less lag).
    public var minCutoff: Float = 1.0   // Hz
    public var beta: Float = 0.5
    /// Low-pass time constant (s) for the prediction velocity estimate.
    public var velocityTimeConstant: Float = 0.084

    /// Live raw-vs-filtered logging (for diagnosing jitter/calibration). Set the sink to route
    /// lines to the debug log; enable the flag to start.
    public var rawLoggingEnabled = false
    public var rawLog: ((String) -> Void)?
    private var lastRawLog: TimeInterval = 0

    private static func eulerDeg(_ q: simd_quatf) -> (y: Float, p: Float, r: Float) {
        let toDeg: Float = 180 / .pi
        let yaw = atan2f(2 * (q.real * q.imag.y + q.imag.x * q.imag.z),
                         1 - 2 * (q.imag.y * q.imag.y + q.imag.x * q.imag.x)) * toDeg
        let pitch = asinf(max(-1, min(1, 2 * (q.real * q.imag.x - q.imag.y * q.imag.z)))) * toDeg
        let roll = atan2f(2 * (q.real * q.imag.z + q.imag.x * q.imag.y),
                          1 - 2 * (q.imag.x * q.imag.x + q.imag.z * q.imag.z)) * toDeg
        return (yaw, pitch, roll)
    }

    private var lastSample: (q: simd_quatf, t: TimeInterval)?
    private var orientationFilter = OneEuroOrientation()
    private var velFiltered: SIMD3<Float> = .zero
}

private func imuEventCallback(
    timestamp: UInt64,
    event: device_imu_event_type,
    ahrs: OpaquePointer?
) {
    if event == DEVICE_IMU_EVENT_UPDATE {
        IMUService.shared.handleUpdate(ahrs)
    }
}

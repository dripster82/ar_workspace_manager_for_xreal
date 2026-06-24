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

/// Outcome of a stationary drift calibration.
public enum DriftCalibrationResult: Sendable {
    case success(driftDegPerMin: Float)  // measured constant yaw drift now being subtracted
    case movedTooMuch                    // the glasses weren't still enough — retry
    case noData                          // disconnected / no samples gathered
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
    private var netDevice = device_imu_net_type()
    private var thread: Thread?
    private var running = false
    private let queue = DispatchQueue(label: "imu.control")

    /// True while the network (XREAL One series) IMU transport is active. The One-series IMU sits
    /// physically tilted in the frame (~39° pitch), so its orientation needs a fixed body-frame
    /// mount correction to bring a level head to level — the Air's IMU is mounted flat and doesn't.
    /// Also used by the app to warn that the glasses' own X1 spatial modes must be off (the One
    /// series can anchor the screen onboard, which double-tracks against this app).
    public private(set) var usingNetworkIMU = false

    /// Body-frame mount correction for the One-series IMU, applied as `raw * correction`. Pitch/roll
    /// validated against real XREAL One Pro motion capture (levels the rest pose and decouples
    /// head-turns from roll). Overridable via ARWM_ONE_TILT_PITCH / ARWM_ONE_TILT_ROLL (degrees).
    private let oneMountCorrection: simd_quatf = {
        let env = ProcessInfo.processInfo.environment
        let pitch = (env["ARWM_ONE_TILT_PITCH"].flatMap { Float($0) } ?? -39) * .pi / 180
        let roll  = (env["ARWM_ONE_TILT_ROLL"].flatMap { Float($0) } ?? -2) * .pi / 180
        let p = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        let r = simd_quatf(angle: roll,  axis: SIMD3(0, 0, 1))
        return simd_normalize(p * r)
    }()

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

    /// Measure the residual yaw drift while the glasses rest still on a flat surface, then subtract
    /// it continuously as a constant gyro-bias correction. `completion` is called on the main queue.
    /// The caller should ask the user to keep the glasses motionless for `duration` seconds.
    public func calibrateDrift(duration: TimeInterval = 4.0,
                               completion: @escaping @Sendable (DriftCalibrationResult) -> Void) {
        queue.async { [self] in
            calibCompletion = completion
            calibDuration = duration
            calibStartTime = 0
            calibMaxSpeedDegS = 0
            calibUnwrappedYaw = 0
            calibrating = true
        }
    }

    private func readLoop() {
        while running {
            // 1) XREAL Air series — IMU is a HID report stream. Unchanged behaviour for Air users.
            var dev = device_imu_type()
            if device_imu_open(&dev, imuEventCallback) == DEVICE_IMU_ERROR_NO_ERROR {
                device = dev
                device_imu_clear(&device)
                usingNetworkIMU = false
                announceConnected(productID: device.product_id, transport: "HID")
                NSLog("IMUService: opened (HID) VID 0x%04x PID 0x%04x", device.vendor_id, device.product_id)
                while running {
                    let r = device_imu_read(&device, 100) // ms timeout
                    if r == DEVICE_IMU_ERROR_UNPLUGGED || r == DEVICE_IMU_ERROR_NO_DEVICE || r == DEVICE_IMU_ERROR_NO_HANDLE {
                        break
                    }
                }
                device_imu_close(&device)
                DispatchQueue.main.async { self.state = .disconnected }
                continue
            }

            // 2) XREAL One series — IMU streams over the glasses' USB-ethernet link (TCP). Only
            //    attempted when no Air HID IMU was found; gated internally on a XREAL device being
            //    plugged in, so it never probes the network otherwise.
            var ndev = device_imu_net_type()
            if device_imu_net_open(&ndev, imuEventCallback) == DEVICE_IMU_ERROR_NO_ERROR {
                netDevice = ndev
                usingNetworkIMU = true
                announceConnected(productID: netDevice.product_id, transport: "network")
                NSLog("IMUService: opened (network) PID 0x%04x", netDevice.product_id)
                while running {
                    let r = device_imu_net_read(&netDevice, 100) // ms timeout
                    if r == DEVICE_IMU_ERROR_UNPLUGGED || r == DEVICE_IMU_ERROR_NO_DEVICE || r == DEVICE_IMU_ERROR_NO_HANDLE {
                        break
                    }
                }
                device_imu_net_close(&netDevice)
                DispatchQueue.main.async { self.state = .disconnected }
                continue
            }

            // 3) Nothing connected — wait and retry.
            DispatchQueue.main.async { self.state = .disconnected }
            Thread.sleep(forTimeInterval: 2.0)
        }
    }

    private func announceConnected(productID: UInt16, transport: String) {
        let name = String(cString: xreal_product_name(productID))
        let product = productID != 0 ? "\(name) (PID 0x\(String(productID, radix: 16)))" : name
        DispatchQueue.main.async { self.state = .connected(product: product) }
    }

    fileprivate func handleUpdate(_ ahrs: OpaquePointer?) {
        guard let ahrs else { return }
        let q = device_imu_get_orientation(ahrs)
        // Driver axes are a cyclic permutation of the render world's (x=pitch, y=yaw, z=roll):
        // driver y carries pitch, z carries yaw, x carries roll. Remap (x,y,z) → (y,z,x),
        // with yaw and roll negated (driver's frame is mirrored on those axes vs. the render world).
        var raw = simd_normalize(simd_quatf(ix: q.y, iy: -q.z, iz: -q.x, r: q.w))
        // One-series IMU is mounted tilted in the frame; bring "level head" to level so the screen
        // sits straight ahead and head-turns don't couple into roll. (No-op for the Air path.)
        if usingNetworkIMU { raw = simd_normalize(raw * oneMountCorrection) }
        let now = CACurrentMediaTime()

        // Estimate instantaneous angular velocity from successive raw orientations.
        let prev = lastSample
        var instAngVel = SIMD3<Float>.zero
        // Floor the interval: at ~1 kHz, timing jitter can give a sub-millisecond dt, and
        // angle/tiny-dt explodes into a spurious velocity spike that snaps the prediction.
        if let prev, now - prev.t > 0.0005 {
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

        // Stationary yaw-drift correction. Yaw has no absolute reference (no magnetometer in
        // the default fusion), so a residual gyro bias slowly rotates the world sideways. When
        // the head is essentially still, ANY change in yaw is drift — so we accumulate the
        // opposite into `driftYaw` (a rotation about world-up) to freeze the heading. It only
        // engages below the stillness threshold, so it never fights a real head turn, and it
        // touches yaw only (pitch/roll are already gravity-locked).
        // Calibrated constant gyro-bias correction: integrate the measured drift rate out of the
        // heading continuously (works even during head turns, unlike the stillness freeze below).
        let biasActive = biasCorrectionEnabled && gyroYawBiasRate != 0
        if biasActive { biasYaw -= gyroYawBiasRate * dt }

        let rawYaw = Self.yaw(of: qSmooth)
        if calibrating { sampleCalibration(rawYaw: rawYaw, now: now) }

        // Stillness freeze observes the bias-corrected heading, so it only cancels the residual
        // (no double-correction with the bias term above).
        let curYaw = rawYaw + (biasActive ? biasYaw : 0)
        if let prev = driftPrevYaw, driftCorrectionEnabled {
            let speedDegS = simd_length(velFiltered) * 180 / .pi
            if speedDegS < driftStillThresholdDegS {
                var dYaw = curYaw - prev
                dYaw = atan2f(sinf(dYaw), cosf(dYaw))   // shortest-path, handles ±π wrap
                driftYaw -= dYaw
            }
        }
        driftPrevYaw = curYaw
        let totalYawCorrection = (driftCorrectionEnabled ? driftYaw : 0) + (biasActive ? biasYaw : 0)
        let corrected = (driftCorrectionEnabled || biasActive)
            ? simd_normalize(simd_quatf(angle: totalYawCorrection, axis: SIMD3(0, 1, 0)) * qSmooth)
            : qSmooth

        poseStore.update(Pose(orientation: corrected, angularVelocity: velFiltered, timestamp: now))

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

    /// Freeze yaw while the head is still to cancel heading drift (see `handleUpdate`).
    public var driftCorrectionEnabled = true
    /// Below this angular speed the head is treated as still and yaw is held.
    public var driftStillThresholdDegS: Float = 1.5

    /// Measured constant yaw-drift rate (rad/s) subtracted continuously. 0 = uncalibrated. Set by
    /// `calibrateDrift`; the app persists/restores it across launches.
    public var gyroYawBiasRate: Float = 0
    private var biasYaw: Float = 0           // running integral of -gyroYawBiasRate·dt
    /// Whether to apply the calibrated bias subtraction. Independent of the stillness freeze.
    /// Toggling restarts the integrator so the heading doesn't jump by the accumulated amount.
    public var biasCorrectionEnabled = true {
        didSet { if biasCorrectionEnabled != oldValue { biasYaw = 0; driftPrevYaw = nil } }
    }

    // Drift-calibration state (mutated on the IMU thread once armed from the control queue).
    private var calibrating = false
    private var calibCompletion: (@Sendable (DriftCalibrationResult) -> Void)?
    private var calibDuration: TimeInterval = 4.0
    private var calibStartTime: TimeInterval = 0
    private var calibStartYaw: Float = 0
    private var calibPrevYaw: Float = 0
    private var calibUnwrappedYaw: Float = 0   // total yaw change over the window (unwrapped)
    private var calibMaxSpeedDegS: Float = 0
    /// If the glasses exceed this speed at any point, they weren't still — calibration fails.
    private let calibStillFailDegS: Float = 3.0

    private func sampleCalibration(rawYaw: Float, now: TimeInterval) {
        calibMaxSpeedDegS = max(calibMaxSpeedDegS, simd_length(velFiltered) * 180 / .pi)
        if calibStartTime == 0 {
            calibStartTime = now
            calibStartYaw = rawYaw
            calibPrevYaw = rawYaw
            calibUnwrappedYaw = 0
            return
        }
        var d = rawYaw - calibPrevYaw
        d = atan2f(sinf(d), cosf(d))            // shortest-path step
        calibUnwrappedYaw += d
        calibPrevYaw = rawYaw
        guard now - calibStartTime >= calibDuration else { return }

        calibrating = false
        let completion = calibCompletion
        calibCompletion = nil
        let elapsed = now - calibStartTime
        let result: DriftCalibrationResult
        if calibMaxSpeedDegS > calibStillFailDegS {
            result = .movedTooMuch
        } else if elapsed > 0.5 {
            gyroYawBiasRate = calibUnwrappedYaw / Float(elapsed)   // rad/s
            biasYaw = 0
            driftPrevYaw = nil                                     // restart the freeze cleanly
            result = .success(driftDegPerMin: gyroYawBiasRate * 180 / .pi * 60)
        } else {
            result = .noData
        }
        if let completion { DispatchQueue.main.async { completion(result) } }
    }

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

    // Drift-corrector state.
    private var driftYaw: Float = 0          // accumulated world-up correction (radians)
    private var driftPrevYaw: Float?         // last smoothed yaw, for delta tracking

    /// Yaw (rotation about world-up) of a quaternion, in radians.
    private static func yaw(of q: simd_quatf) -> Float {
        atan2f(2 * (q.real * q.imag.y + q.imag.x * q.imag.z),
               1 - 2 * (q.imag.y * q.imag.y + q.imag.x * q.imag.x))
    }
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

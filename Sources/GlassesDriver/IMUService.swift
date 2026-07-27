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
    /// Set to bounce the inner read loop: close and re-probe the device without stopping the
    /// thread. Needed because a device that is open but silently delivering nothing (issue #3 —
    /// glasses in their onboard follow mode, or a wedged HID stream) never returns an error from
    /// `device_imu_read`, so the loop spins forever and the 2s re-probe never engages.
    private var restartRequested = false
    /// Latest IMU temperature (°C), read AFTER each `device_imu_read` returns. We must NOT touch
    /// `device` inside `handleUpdate` (the callback runs while `&device` is held inout by the read,
    /// and a concurrent access trips Swift's exclusivity check → abort), so we stash it here.
    private var lastTemperature: Float = 0
    private let queue = DispatchQueue(label: "imu.control")

    /// True while the network (XREAL One series) IMU transport is active. The One-series IMU sits
    /// physically tilted in the frame (~39° pitch), so its orientation needs a fixed body-frame
    /// mount correction to bring a level head to level — the Air's IMU is mounted flat and doesn't.
    /// Also used by the app to warn that the glasses' own X1 spatial modes must be off (the One
    /// series can anchor the screen onboard, which double-tracks against this app).
    public private(set) var usingNetworkIMU = false

    /// Body-frame mount correction for the One-series IMU, applied as `raw * correction`. The One IMU
    /// sits tilted in the frame, so without this a level head reads pitched/rolled and head-turns
    /// couple into roll. The exact tilt varies per model (One Pro ≈ −39°, One S measured larger), so
    /// it is *measured per device* by calibration and persisted (see `applyMountCalibration`). Until a
    /// device is calibrated this falls back to the One Pro values (overridable via the env vars).
    /// Mutated and read only on the IMU read thread (announceConnected / handleUpdate / completion).
    private var oneMountCorrection: simd_quatf = IMUService.defaultMountCorrection()

    /// Build the body-frame correction quaternion from a pitch+roll tilt (degrees), matching the
    /// One Pro-validated structure (pitch about X, then roll about Z).
    static func mountCorrection(pitchDeg: Float, rollDeg: Float) -> simd_quatf {
        let p = simd_quatf(angle: pitchDeg * .pi / 180, axis: SIMD3(1, 0, 0))
        let r = simd_quatf(angle: rollDeg  * .pi / 180, axis: SIMD3(0, 0, 1))
        return simd_normalize(p * r)
    }

    private static func defaultMountCorrection() -> simd_quatf {
        let env = ProcessInfo.processInfo.environment
        let pitch = env["ARWM_ONE_TILT_PITCH"].flatMap { Float($0) } ?? -39
        let roll  = env["ARWM_ONE_TILT_ROLL"].flatMap { Float($0) } ?? -2
        return mountCorrection(pitchDeg: pitch, rollDeg: roll)
    }

    /// Product ID of the currently connected glasses (0 = none). Set on connect.
    public private(set) var connectedProductID: UInt16 = 0
    /// True when the connected One-series device has a saved (or just-measured) mount calibration.
    /// For Air (HID) devices this is always true — they need no mount correction. The app reads this
    /// on AR-start to require a first-use calibration for an uncalibrated One-series device.
    public private(set) var hasMountCalibration = true

    private func mountTiltKey(_ productID: UInt16) -> String { "oneMountTilt.\(productID)" }

    /// The mount-tilt correction currently in effect for the connected device, in degrees:
    /// the saved per-device calibration, else the One Pro defaults. For the Settings editor.
    public var mountCalibrationDegrees: (pitch: Double, roll: Double) {
        if connectedProductID != 0,
           let arr = UserDefaults.standard.array(forKey: mountTiltKey(connectedProductID)) as? [Double],
           arr.count == 2 {
            return (arr[0], arr[1])
        }
        let env = ProcessInfo.processInfo.environment
        return (Double(env["ARWM_ONE_TILT_PITCH"].flatMap { Float($0) } ?? -39),
                Double(env["ARWM_ONE_TILT_ROLL"].flatMap { Float($0) } ?? -2))
    }

    /// Manually set + persist the mount-tilt correction (Settings editor, 0.1° nudges).
    /// `oneMountCorrection` itself is only touched on the IMU read thread, so the new value is
    /// handed off via a lock-guarded pending slot that handleUpdate applies on its next sample.
    private let mountSetLock = NSLock()
    private var pendingMountSet: (pitch: Float, roll: Float)?
    private var pendingDriftSet: Float?          // rad/s
    private var hasPendingMountSet = false
    public func setMountCalibration(pitchDeg: Double, rollDeg: Double) {
        guard connectedProductID != 0 else { return }
        UserDefaults.standard.set([pitchDeg, rollDeg], forKey: mountTiltKey(connectedProductID))
        mountSetLock.lock()
        pendingMountSet = (Float(pitchDeg), Float(rollDeg))
        hasPendingMountSet = true
        mountSetLock.unlock()
        hasMountCalibration = true
    }

    /// The yaw-drift compensation currently in effect, in °/min (what ⌃⌥B measures; 0 until a
    /// calibration has run this session — it is not persisted, drift varies day to day).
    public var driftCompensationDegPerMin: Double { Double(gyroYawBiasRate) * 180 / .pi * 60 }

    /// Manually set the yaw-drift compensation (Settings editor). Same IMU-thread handoff as the
    /// mount set — the bias is read every sample on the IMU thread.
    public func setDriftCompensation(degPerMin: Double) {
        mountSetLock.lock()
        pendingDriftSet = Float(degPerMin * .pi / 180 / 60)
        hasPendingMountSet = true
        mountSetLock.unlock()
    }

    /// Load and apply the saved per-device mount tilt, if any. Returns whether one was found.
    @discardableResult
    private func loadMountCalibration(productID: UInt16) -> Bool {
        guard let arr = UserDefaults.standard.array(forKey: mountTiltKey(productID)) as? [Double],
              arr.count == 2 else { return false }
        oneMountCorrection = Self.mountCorrection(pitchDeg: Float(arr[0]), rollDeg: Float(arr[1]))
        return true
    }

    /// Persist + apply a freshly measured mount tilt (correction angles, degrees) for a device.
    private func saveMountCalibration(productID: UInt16, pitchDeg: Float, rollDeg: Float) {
        UserDefaults.standard.set([Double(pitchDeg), Double(rollDeg)], forKey: mountTiltKey(productID))
        oneMountCorrection = Self.mountCorrection(pitchDeg: pitchDeg, rollDeg: rollDeg)
    }

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

    /// Close and reopen the device without stopping the read thread. Idempotent — safe to call
    /// repeatedly (e.g. from a watchdog); a no-op when the service isn't running or the loop is
    /// already in its between-devices re-probe. Takes effect within ~100ms (the read timeout).
    public func restart() {
        queue.async { [self] in
            guard running else { return }
            restartRequested = true
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
            calibTiltPitchSum = 0
            calibTiltRollSum = 0
            calibTiltCount = 0
            calibrating = true
        }
    }

    private func readLoop() {
        while running {
            // A restart request arriving while we're between devices is already satisfied by the
            // probe below — clear it so it can't immediately bounce the next successful open.
            restartRequested = false
            // 1) XREAL Air series — IMU is a HID report stream. Unchanged behaviour for Air users.
            var dev = device_imu_type()
            if device_imu_open(&dev, imuEventCallback) == DEVICE_IMU_ERROR_NO_ERROR {
                device = dev
                device_imu_clear(&device)
                usingNetworkIMU = false
                announceConnected(productID: device.product_id, transport: "HID")
                NSLog("IMUService: opened (HID) VID 0x%04x PID 0x%04x", device.vendor_id, device.product_id)
                while running, !restartRequested {
                    let r = device_imu_read(&device, 100) // ms timeout
                    if r == DEVICE_IMU_ERROR_UNPLUGGED || r == DEVICE_IMU_ERROR_NO_DEVICE || r == DEVICE_IMU_ERROR_NO_HANDLE {
                        break
                    }
                    lastTemperature = device.temperature  // safe here: the read's inout access has ended
                }
                device_imu_close(&device)
                if restartRequested {
                    restartRequested = false
                    NSLog("IMUService: restart requested — reopening device (HID)")
                }
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
                while running, !restartRequested {
                    let r = device_imu_net_read(&netDevice, 100) // ms timeout
                    if r == DEVICE_IMU_ERROR_UNPLUGGED || r == DEVICE_IMU_ERROR_NO_DEVICE || r == DEVICE_IMU_ERROR_NO_HANDLE {
                        break
                    }
                    lastTemperature = netDevice.temperature  // One-series IMU temperature
                }
                device_imu_net_close(&netDevice)
                if restartRequested {
                    restartRequested = false
                    NSLog("IMUService: restart requested — reopening device (network)")
                }
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
        connectedProductID = productID
        // One-series glasses need a measured mount tilt; Air (HID) does not. Apply any saved
        // calibration now, and flag whether a first-use calibration is still required.
        if usingNetworkIMU {
            let calibrated = loadMountCalibration(productID: productID)
            if !calibrated { oneMountCorrection = Self.defaultMountCorrection() }
            hasMountCalibration = calibrated
        } else {
            hasMountCalibration = true
        }
        DispatchQueue.main.async { self.state = .connected(product: product) }
    }

    fileprivate func handleUpdate(_ ahrs: OpaquePointer?) {
        guard let ahrs else { return }
        let q = device_imu_get_orientation(ahrs)
        // Driver axes are a cyclic permutation of the render world's (x=pitch, y=yaw, z=roll):
        // driver y carries pitch, z carries yaw, x carries roll. Remap (x,y,z) → (y,z,x),
        // with yaw and roll negated (driver's frame is mirrored on those axes vs. the render world).
        var raw = simd_normalize(simd_quatf(ix: q.y, iy: -q.z, iz: -q.x, r: q.w))
        // Pre-correction device tilt (gravity-locked pitch/roll) — sampled during calibration to
        // measure this device's physical mount tilt. Captured before the correction is applied.
        let preCorrection: (p: Float, r: Float)? = (usingNetworkIMU && calibrating)
            ? { let e = Self.eulerDeg(raw); return (e.p, e.r) }() : nil
        // One-series IMU is mounted tilted in the frame; bring "level head" to level so the screen
        // sits straight ahead and head-turns don't couple into roll. (No-op for the Air path.)
        if hasPendingMountSet {   // manual Settings edit — apply on the IMU thread (owner)
            mountSetLock.lock()
            if let p = pendingMountSet {
                oneMountCorrection = Self.mountCorrection(pitchDeg: p.pitch, rollDeg: p.roll)
            }
            if let d = pendingDriftSet { gyroYawBiasRate = d }
            pendingMountSet = nil
            pendingDriftSet = nil
            hasPendingMountSet = false
            mountSetLock.unlock()
        }
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
        if calibrating { sampleCalibration(rawYaw: rawYaw, now: now, tilt: preCorrection) }

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

        // Linear acceleration (gravity removed) from the fusion, and the IMU temperature (on the
        // device struct, updated by the read that triggered this callback).
        let la = device_imu_get_linear_acceleration(ahrs)
        let accel = SIMD3<Float>(la.x, la.y, la.z)
        poseStore.update(Pose(orientation: corrected, angularVelocity: velFiltered, timestamp: now,
                              acceleration: accel, temperature: lastTemperature))

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
    // One-series mount-tilt capture: accumulate the device's pre-correction pitch/roll (gravity-locked,
    // so a still+level head reads the raw mount tilt) over the still window and average at completion.
    private var calibTiltPitchSum: Float = 0
    private var calibTiltRollSum: Float = 0
    private var calibTiltCount: Int = 0

    private func sampleCalibration(rawYaw: Float, now: TimeInterval, tilt: (p: Float, r: Float)?) {
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
        if let tilt { calibTiltPitchSum += tilt.p; calibTiltRollSum += tilt.r; calibTiltCount += 1 }
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
            // One-series mount-tilt: cancel the averaged level-rest tilt so head-turns stop coupling
            // into roll. Persisted per device so this device is calibrated for next time.
            if usingNetworkIMU, calibTiltCount > 0 {
                let avgPitch = calibTiltPitchSum / Float(calibTiltCount)
                let avgRoll  = calibTiltRollSum  / Float(calibTiltCount)
                saveMountCalibration(productID: connectedProductID, pitchDeg: -avgPitch, rollDeg: -avgRoll)
                hasMountCalibration = true
                NSLog("IMUService: mount calibrated PID 0x%04x — tilt p%+.2f r%+.2f° (correction p%+.2f r%+.2f)",
                      connectedProductID, avgPitch, avgRoll, -avgPitch, -avgRoll)
            }
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

    /// One-shot hex dump of the One-series network IMU stream, for diagnosing unknown frame
    /// layouts in the field (e.g. a unit with a different header byte). Lines arrive on the IMU
    /// read thread via `netDumpSink`. Arming persists until the byte budget is spent, so it's
    /// safe to press before the glasses connect. No-op for Air (HID) glasses.
    public var netDumpSink: ((String) -> Void)?
    public func requestNetworkDump(bytes: Int = 1024) {
        device_imu_net_set_dump_callback(imuNetDumpCallback)
        device_imu_net_request_dump(bytes)
    }

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

private func imuNetDumpCallback(_ line: UnsafePointer<CChar>?) {
    guard let line else { return }
    IMUService.shared.netDumpSink?(String(cString: line))
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

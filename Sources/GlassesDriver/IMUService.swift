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

    public func recenter() { poseStore.recenter() }

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
        let orientation = simd_normalize(simd_quatf(ix: q.y, iy: -q.z, iz: -q.x, r: q.w))
        let now = CACurrentMediaTime()

        // Estimate angular velocity from successive orientations for prediction.
        let prev = lastSample
        var angVel = SIMD3<Float>.zero
        if let prev, now > prev.t {
            let dq = orientation * prev.q.inverse
            let angle = 2 * acosf(min(1, abs(dq.real)))
            if angle > 1e-5 {
                let s = sqrtf(max(1e-10, 1 - dq.real * dq.real))
                let axis = SIMD3(dq.imag.x / s, dq.imag.y / s, dq.imag.z / s)
                angVel = axis * (angle / Float(now - prev.t)) * (dq.real < 0 ? -1 : 1)
            }
        }
        lastSample = (orientation, now)
        poseStore.update(Pose(orientation: orientation, angularVelocity: angVel, timestamp: now))
    }

    private var lastSample: (q: simd_quatf, t: TimeInterval)?
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

import CXrealDriver
import Foundation

/// Control channel to the glasses' MCU (brightness etc.). Opened lazily; all access
/// is serialized on its own queue since the C driver is not thread-safe.
public final class MCUService: @unchecked Sendable {
    public static let shared = MCUService()

    private let queue = DispatchQueue(label: "mcu.control")
    private var device = device_mcu_type()
    private var isOpen = false

    private init() {}

    /// Current brightness 0–7, or nil if the glasses aren't reachable.
    public func brightness(completion: @escaping @Sendable (Int?) -> Void) {
        queue.async { [self] in
            completion(openIfNeeded() ? Int(device.brightness) : nil)
        }
    }

    public func setBrightness(_ value: Int, completion: (@Sendable (Bool) -> Void)? = nil) {
        queue.async { [self] in
            guard openIfNeeded() else { completion?(false); return }
            let err = device_mcu_set_brightness(&device, UInt8(max(0, min(7, value))))
            if err == DEVICE_MCU_ERROR_UNPLUGGED || err == DEVICE_MCU_ERROR_NO_HANDLE {
                closeDevice() // stale handle after replug — retry once with a fresh open
                if openIfNeeded() {
                    completion?(device_mcu_set_brightness(&device, UInt8(max(0, min(7, value)))) == DEVICE_MCU_ERROR_NO_ERROR)
                    return
                }
            }
            completion?(err == DEVICE_MCU_ERROR_NO_ERROR)
        }
    }

    public func disconnect() {
        queue.async { [self] in closeDevice() }
    }

    private func openIfNeeded() -> Bool {
        if isOpen { return true }
        var dev = device_mcu_type()
        guard device_mcu_open(&dev, nil) == DEVICE_MCU_ERROR_NO_ERROR else { return false }
        device = dev
        device_mcu_clear(&device)
        isOpen = true
        return true
    }

    private func closeDevice() {
        if isOpen {
            device_mcu_close(&device)
            isOpen = false
        }
    }
}

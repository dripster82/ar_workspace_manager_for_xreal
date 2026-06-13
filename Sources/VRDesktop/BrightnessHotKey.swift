import AppKit
import ApplicationServices

/// Intercepts the Mac brightness keys while ⌃⌥ is held and routes them to the glasses,
/// consuming the event so macOS doesn't also act (Option+brightness opens Displays prefs).
/// Requires Accessibility permission (CGEventTap).
final class BrightnessHotKey {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: ((Bool) -> Void)?

    // From IOKit/hidsystem/ev_keymap.h
    private static let brightnessUp = 2
    private static let brightnessDown = 3
    private static let systemDefinedAuxSubtype = 8

    var isRunning: Bool { tap != nil }

    /// Starts the tap. Returns false if Accessibility permission is missing.
    @discardableResult
    func start(handler: @escaping (Bool) -> Void) -> Bool {
        guard tap == nil else { return true }
        self.handler = handler

        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED (system-defined / media keys)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: eventTapCallback, userInfo: context)
        else {
            return false // no Accessibility permission
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        runLoopSource = nil
        tap = nil
    }

    func reEnable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// True if Accessibility is granted; pass prompt=true to show the system request.
    static func accessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Returns true and consumes the event if it's a ⌃⌥+brightness press we handled.
    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == Self.systemDefinedAuxSubtype else { return false }
        let data1 = ns.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyDown = ((data1 & 0x0000FF00) >> 8) == 0x0A
        guard keyDown, ns.modifierFlags.contains(.control), ns.modifierFlags.contains(.option),
              keyCode == Self.brightnessUp || keyCode == Self.brightnessDown else { return false }
        let up = keyCode == Self.brightnessUp
        DispatchQueue.main.async { self.handler?(up) }
        return true
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                              event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<BrightnessHotKey>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        owner.reEnable()
        return Unmanaged.passUnretained(event)
    }
    if owner.handle(event) { return nil } // consume so macOS doesn't also react
    return Unmanaged.passUnretained(event)
}

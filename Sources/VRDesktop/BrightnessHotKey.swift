import AppKit
import ApplicationServices

/// Intercepts the Mac brightness keys while ⌃⌥ is held and routes them to the glasses,
/// consuming the event so macOS doesn't also act (Option+brightness opens Displays prefs).
/// Requires Accessibility permission (CGEventTap).
///
/// Two hard rules, learned from a long stuck-drag hunt (2026-07-08): NX_SYSDEFINED is not just
/// media keys — subtype-7 events carry auxiliary MOUSE BUTTON state for every click system-wide,
/// and a consuming head-insert tap sits synchronously in that delivery path. So:
///  - **The tap is enabled ONLY while ⌃⌥ is held** (flags-changed monitors toggle it). During
///    normal mousing it is disabled and macOS delivers events without consulting us at all.
///  - **The tap's callback runs on a dedicated thread**, never the main run loop — a busy main
///    thread must not delay (or reorder) system-wide input events; delayed button-state around a
///    drag release is exactly how drags get stuck to the cursor until Esc.
final class BrightnessHotKey {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var handler: ((Bool) -> Void)?
    private var flagsMonitors: [Any] = []
    /// Whether ⌃⌥ is currently held (i.e. the tap should be live). Written on main.
    private var wantEnabled = false

    // From IOKit/hidsystem/ev_keymap.h
    private static let brightnessUp = 2
    private static let brightnessDown = 3
    private static let systemDefinedAuxSubtype = 8

    var isRunning: Bool { tap != nil }

    /// Starts the tap (disabled until ⌃⌥ is held). Returns false if Accessibility is missing.
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
        CGEvent.tapEnable(tap: tap, enable: false)   // inert until ⌃⌥ is held

        // Dedicated run-loop thread for the tap source: system-wide event delivery must never
        // queue behind the app's main thread.
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "BrightnessHotKeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread

        // Enable the tap only while both ⌃ and ⌥ are down. Flags monitors are observe-only and
        // cheap; tapEnable is a mach-port op, safe from main while the tap lives on its thread.
        let update: (NSEvent) -> Void = { [weak self] ev in
            guard let self, let tap = self.tap else { return }
            let want = ev.modifierFlags.contains(.control) && ev.modifierFlags.contains(.option)
            if want != self.wantEnabled {
                self.wantEnabled = want
                CGEvent.tapEnable(tap: tap, enable: want)
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { update($0) }) {
            flagsMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { update($0); return $0 }) {
            flagsMonitors.append(l)
        }
        return true
    }

    func stop() {
        flagsMonitors.forEach { NSEvent.removeMonitor($0) }
        flagsMonitors.removeAll()
        wantEnabled = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource, let rl = tapRunLoop {
            CFRunLoopRemoveSource(rl, source, .commonModes)
            CFRunLoopStop(rl)
        }
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        tap = nil
    }

    /// Re-enable after a timeout disable — but only if ⌃⌥ is still held (otherwise stay inert).
    func reEnable() {
        if let tap, wantEnabled { CGEvent.tapEnable(tap: tap, enable: true) }
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

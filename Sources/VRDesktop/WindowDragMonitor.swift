import AppKit
@preconcurrency import ApplicationServices

/// Detects when the user is dragging a window around the desktop (as opposed to just moving the
/// mouse, selecting text, or dragging a scrollbar), to drive the in-AR dot-grid guide. It watches
/// the left mouse button via event monitors; once a drag looks plausible it uses Accessibility to
/// find the window under the cursor, and a drag only counts when that window's position actually
/// changes while the button is held.
///
/// Two hard rules, learned the slow way (2026-07: every system-wide click felt sluggish and could
/// turn into a phantom drag):
///  - **mouseDown does ZERO Accessibility work.** The hit-test is deferred until the first drag
///    event of a press — plain clicks never pay for it.
///  - **No AX call ever runs on the main thread.** All round-trips go through a private serial
///    queue; a slow AX target (Electron windows, the Open/Save panel's XPC service) can stall that
///    queue for ≤0.15 s per call, never the app. Results hop back to main and are dropped if the
///    press they belong to has already ended (`pressGeneration`).
///
/// Needs the Accessibility permission (the app already uses it for window moving). Without it the
/// hit-test fails and `isDragging` simply stays false.
@MainActor
final class WindowDragMonitor {
    /// True while a window is being dragged. Changes are pushed to `onChange` (main actor).
    private(set) var isDragging = false {
        didSet { if isDragging != oldValue { onChange?(isDragging) } }
    }
    var onChange: ((Bool) -> Void)?

    private var monitors: [Any] = []
    private let systemWide = AXUIElementCreateSystemWide()
    /// All AX round-trips happen here — never on main.
    private let axQueue = DispatchQueue(label: "vrdesktop.windowdrag.ax", qos: .userInitiated)
    /// Bumped on every mouse down AND up, so an async AX result from a press that has already
    /// ended can never attach itself to the next press.
    private var pressGeneration: UInt64 = 0
    private var buttonDown = false
    private var hitTestInFlight = false
    private var pollInFlight = false
    private var lastPollTime: CFTimeInterval = 0
    /// The dot grid only needs coarse "is a window moving" detection — poll at ≤10 Hz, not at the
    /// 60–120 Hz drag-event rate.
    private static let pollInterval: CFTimeInterval = 0.1
    private var pressedWindow: AXUIElement?
    private var startWindowPos: CGPoint?

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        // Belt-and-braces: cap AX messaging so a wedged AX server holds the private queue for at
        // most 0.15 s per call (the queue is disposable time; the main thread never waits on it).
        AXUIElementSetMessagingTimeout(systemWide, 0.15)
        add([.leftMouseDown]) { [weak self] in self?.handleDown() }
        add([.leftMouseDragged]) { [weak self] in self?.handleDrag() }
        add([.leftMouseUp]) { [weak self] in self?.handleUp() }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        pressGeneration &+= 1
        resetPress()
        isDragging = false
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ action: @escaping () -> Void) {
        // Global: events headed to other apps (where the dragged windows live). Local: our own app.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated { action() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            action(); return event
        }) { monitors.append(l) }
    }

    private func handleDown() {
        pressGeneration &+= 1
        buttonDown = true
        resetPress()
        // Deliberately NO hit-test here — see the header comment. It happens on the first drag.
    }

    private func handleDrag() {
        guard buttonDown, !isDragging else { return }   // once dragging, nothing left to learn
        let gen = pressGeneration
        if pressedWindow == nil {
            // First drag event of this press: async hit-test for the window under the cursor.
            // The position baseline is therefore captured a few px into the drag; a real window
            // drag keeps moving, so the next poll still crosses the 2 px threshold. (Degenerate
            // case: flick-then-freeze with the button held — the grid appears on the next move.)
            guard !hitTestInFlight else { return }
            hitTestInFlight = true
            let p = cgMouseLocation()
            let sysWide = systemWide
            axQueue.async { [weak self] in
                var found: (window: AXUIElement, pos: CGPoint)?
                var element: AXUIElement?
                if AXUIElementCopyElementAtPosition(sysWide, Float(p.x), Float(p.y), &element) == .success,
                   let element, let window = Self.enclosingWindow(of: element),
                   let pos = Self.axPosition(of: window) {
                    found = (window, pos)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, gen == self.pressGeneration else { return }  // press ended — stale
                        self.hitTestInFlight = false
                        if let found {
                            self.pressedWindow = found.window
                            self.startWindowPos = found.pos
                        } else {
                            self.buttonDown = false   // nothing draggable under the cursor — done for this press
                        }
                    }
                }
            }
        } else if let window = pressedWindow, let start = startWindowPos {
            let now = CACurrentMediaTime()
            guard !pollInFlight, now - lastPollTime >= Self.pollInterval else { return }
            pollInFlight = true
            lastPollTime = now
            axQueue.async { [weak self] in
                let pos = Self.axPosition(of: window)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, gen == self.pressGeneration else { return }
                        self.pollInFlight = false
                        // Only a real window move counts — this excludes in-window drags like
                        // selecting text or dragging a scrollbar, where the window stays put.
                        if let pos, hypot(pos.x - start.x, pos.y - start.y) > 2 {
                            self.isDragging = true
                        }
                    }
                }
            }
        }
    }

    private func handleUp() {
        pressGeneration &+= 1
        buttonDown = false
        resetPress()
        isDragging = false
    }

    private func resetPress() {
        pressedWindow = nil
        startWindowPos = nil
        hitTestInFlight = false
        pollInFlight = false
        lastPollTime = 0
    }

    // MARK: AX helpers (nonisolated — they run on axQueue, never on main)

    /// The window (AXWindow) containing `element`: its `AXWindow` attribute, else walk up parents.
    private nonisolated static func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        if let win = copyElement(element, kAXWindowAttribute) { return win }
        var current: AXUIElement? = element
        for _ in 0..<12 {            // bounded walk up the hierarchy
            guard let c = current else { break }
            if role(of: c) == (kAXWindowRole as String) { return c }
            current = copyElement(c, kAXParentAttribute)
        }
        return nil
    }

    private nonisolated static func axPosition(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &point)
        return point
    }

    private nonisolated static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private nonisolated static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// NSEvent.mouseLocation (bottom-left origin) → global CG coords (top-left origin) for AX.
    /// Main-actor (reads AppKit state); called before hopping to axQueue.
    private func cgMouseLocation() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.screens.first)?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}

import AppKit
import ApplicationServices

/// Detects when the user is dragging a window around the desktop (as opposed to just moving the
/// mouse, selecting text, or dragging a scrollbar). It watches the left mouse button via a global
/// event monitor, and on press uses Accessibility to find the window under the cursor; a drag only
/// counts once that window's position actually changes while the button is held.
///
/// Needs the Accessibility permission (the app already uses it for window moving). Without it the
/// hit-test fails and `isDragging` simply stays false.
@MainActor
final class WindowDragMonitor {
    /// True while a window is being dragged. Changes are pushed to `onChange`.
    private(set) var isDragging = false {
        didSet { if isDragging != oldValue { onChange?(isDragging) } }
    }
    /// Called on the main actor whenever `isDragging` flips.
    var onChange: ((Bool) -> Void)?
    /// Called when a drag finishes (mouse up after an actual move), with the window's final position.
    var onDrop: ((CGPoint) -> Void)?

    private var monitors: [Any] = []
    private let systemWide = AXUIElementCreateSystemWide()
    private var pressedWindow: AXUIElement?
    private var startWindowPos: CGPoint?

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        // Cap AX messaging: `handleDown` hit-tests the window under the cursor on EVERY left-click via
        // AXUIElementCopyElementAtPosition. If the target is slow or out-of-process (e.g. the Open/Save
        // panel's XPC service), the default ~6s AX timeout would block the main thread on every click.
        // A short cap makes the worst case negligible (drag hit-test is best-effort anyway).
        AXUIElementSetMessagingTimeout(systemWide, 0.15)
        let down: NSEvent.EventTypeMask = [.leftMouseDown]
        let drag: NSEvent.EventTypeMask = [.leftMouseDragged]
        let up: NSEvent.EventTypeMask = [.leftMouseUp]

        add(down) { [weak self] in self?.handleDown() }
        add(drag) { [weak self] in self?.handleDrag() }
        add(up) { [weak self] in self?.handleUp() }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        reset()
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
        let p = cgMouseLocation()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &element) == .success,
              let element, let window = enclosingWindow(of: element) else {
            reset(); return
        }
        pressedWindow = window
        startWindowPos = axPosition(of: window)
    }

    private func handleDrag() {
        guard let window = pressedWindow, let start = startWindowPos,
              let now = axPosition(of: window) else { return }
        // Only a real window move (position changed past a tiny threshold) counts — this excludes
        // in-window drags like selecting text or dragging a scrollbar, where the window stays put.
        if hypot(now.x - start.x, now.y - start.y) > 2 { isDragging = true }
    }

    private func handleUp() {
        if isDragging, let window = pressedWindow, let pos = axPosition(of: window) {
            onDrop?(pos)
        }
        isDragging = false
        pressedWindow = nil
        startWindowPos = nil
    }

    private func reset() {
        pressedWindow = nil
        startWindowPos = nil
        isDragging = false
    }

    // MARK: AX helpers

    /// The window (AXWindow) containing `element`: its `AXWindow` attribute, else walk up parents.
    private func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        if let win = copyElement(element, kAXWindowAttribute) { return win }
        var current: AXUIElement? = element
        for _ in 0..<12 {            // bounded walk up the hierarchy
            guard let c = current else { break }
            if role(of: c) == (kAXWindowRole as String) { return c }
            current = copyElement(c, kAXParentAttribute)
        }
        return nil
    }

    private func axPosition(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &point)
        return point
    }

    private func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// NSEvent.mouseLocation (bottom-left origin) → global CG coords (top-left origin) for AX.
    private func cgMouseLocation() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.screens.first)?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}

import AppKit

/// Keeps the mouse cursor constrained relative to a display while AR is running. Two modes:
/// `offDisplay` warps the cursor back if it wanders onto the AR output (default); `confineTo`
/// keeps it *inside* one display (focus mode), clamping to the edge if it tries to leave.
final class CursorConfiner {
    enum Mode: Equatable {
        case offDisplay(CGDirectDisplayID)   // keep the cursor OFF this display (AR output)
        case confineTo(CGDirectDisplayID)    // keep the cursor INSIDE this display (focus mode)
    }

    private var monitors: [Any] = []
    private var mode: Mode?
    private var lastAllowed: CGPoint = .zero

    var isActive: Bool { !monitors.isEmpty }

    /// Start (or re-target) confinement. Switching mode while already running just updates the
    /// target — the event monitors stay installed, so there's no gap.
    func start(mode: Mode) {
        let wasActive = !monitors.isEmpty
        self.mode = mode
        lastAllowed = toCG(NSEvent.mouseLocation)
        guard !wasActive else { return }

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged,
                                           .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.enforce()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.enforce()
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        mode = nil
    }

    private func frame(of displayID: CGDirectDisplayID) -> CGRect? {
        NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        })?.frame
    }

    private func enforce() {
        guard let mode else { return }
        let location = NSEvent.mouseLocation
        switch mode {
        case .offDisplay(let id):
            guard let frame = frame(of: id) else { return }
            if frame.contains(location) {
                CGWarpMouseCursorPosition(lastAllowed)
                CGAssociateMouseAndMouseCursorPosition(1) // resync hardware delta after warp
            } else {
                lastAllowed = toCG(location)
            }
        case .confineTo(let id):
            guard let frame = frame(of: id) else { return }
            // Clamp to just inside the display's edges so dragging to an edge sticks naturally.
            if !frame.contains(location) {
                let x = min(max(location.x, frame.minX + 1), frame.maxX - 1)
                let y = min(max(location.y, frame.minY + 1), frame.maxY - 1)
                CGWarpMouseCursorPosition(toCG(NSPoint(x: x, y: y)))
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
    }

    /// AppKit mouse coords (bottom-left origin) → CoreGraphics global coords (top-left origin).
    private func toCG(_ point: NSPoint) -> CGPoint {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.screens.first)?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

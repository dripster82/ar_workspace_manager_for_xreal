import AppKit

/// Keeps the mouse cursor off the AR output display while AR is running: if the cursor
/// wanders onto that display, it's warped back to its last position on an allowed screen.
final class CursorConfiner {
    private var monitors: [Any] = []
    private var arDisplayID: CGDirectDisplayID = 0
    private var lastAllowed: CGPoint = .zero

    var isActive: Bool { !monitors.isEmpty }

    func start(arDisplayID: CGDirectDisplayID) {
        stop()
        self.arDisplayID = arDisplayID
        lastAllowed = toCG(NSEvent.mouseLocation)

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
        arDisplayID = 0
    }

    private func enforce() {
        guard arDisplayID != 0,
              let frame = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == arDisplayID
              })?.frame else { return }
        let location = NSEvent.mouseLocation
        if frame.contains(location) {
            CGWarpMouseCursorPosition(lastAllowed)
            CGAssociateMouseAndMouseCursorPosition(1) // resync hardware delta after warp
        } else {
            lastAllowed = toCG(location)
        }
    }

    /// AppKit mouse coords (bottom-left origin) → CoreGraphics global coords (top-left origin).
    private func toCG(_ point: NSPoint) -> CGPoint {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.screens.first)?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

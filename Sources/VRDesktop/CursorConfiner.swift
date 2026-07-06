import AppKit

/// Keeps the mouse cursor constrained relative to a display while AR is running. Two modes:
/// `offDisplay` warps the cursor back if it wanders onto the AR output (default); `confineTo`
/// keeps it *inside* one display (focus mode), clamping to the edge if it tries to leave.
final class CursorConfiner {
    enum Mode: Equatable {
        case offDisplay(CGDirectDisplayID)        // keep the cursor OFF this display (AR output)
        case confineTo(CGDirectDisplayID)         // keep the cursor INSIDE this display (focus mode)
        case confineToDisplays(Set<CGDirectDisplayID>) // keep it INSIDE this set (headless: the
                                                  // virtual AR screens, when the glasses are the
                                                  // only physical display)
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

        // Mouse-up events included so a correction deferred during a click/drag (we never warp
        // while a button is down) is applied promptly on release even if the mouse doesn't move.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged,
                                           .rightMouseDragged, .otherMouseDragged,
                                           .leftMouseUp, .rightMouseUp, .otherMouseUp]
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
                // NEVER warp while a button is held: the AR output sits edge-to-edge with the
                // physical screen, so a click that overshoots the shared edge lands here — and a
                // warp between press and release reads to macOS as a huge fast mouse movement,
                // reclassifying the click as a drag (files "sticking" to the cursor until Esc).
                // Defer; the mouse-up event in the mask triggers the correction on release.
                guard NSEvent.pressedMouseButtons == 0 else { return }
                // Push to the nearest point just OUTSIDE the AR display that lies on a real
                // screen — the shared edge acts as a wall (a ~1px correction) instead of
                // teleporting back to a stale remembered position across the screen.
                let exits = [NSPoint(x: frame.maxX + 1, y: location.y),
                             NSPoint(x: frame.minX - 1, y: location.y),
                             NSPoint(x: location.x, y: frame.maxY + 1),
                             NSPoint(x: location.x, y: frame.minY - 1)]
                    .filter { p in NSScreen.screens.contains { $0.frame.contains(p) } }
                    .min { hypot($0.x - location.x, $0.y - location.y)
                         < hypot($1.x - location.x, $1.y - location.y) }
                CGWarpMouseCursorPosition(exits.map(toCG) ?? lastAllowed)
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
        case .confineToDisplays(let ids):
            let frames = ids.compactMap { frame(of: $0) }
            guard !frames.isEmpty else { return }                 // nothing to confine to → no-op
            if frames.contains(where: { $0.contains(location) }) {
                lastAllowed = toCG(location)
                return
            }
            // Outside every allowed display → warp to the nearest point just inside the closest one.
            var best: NSPoint?
            var bestDist = CGFloat.greatestFiniteMagnitude
            for f in frames {
                let cx = min(max(location.x, f.minX + 1), f.maxX - 1)
                let cy = min(max(location.y, f.minY + 1), f.maxY - 1)
                let d = hypot(location.x - cx, location.y - cy)
                if d < bestDist { bestDist = d; best = NSPoint(x: cx, y: cy) }
            }
            if let b = best {
                CGWarpMouseCursorPosition(toCG(b))
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

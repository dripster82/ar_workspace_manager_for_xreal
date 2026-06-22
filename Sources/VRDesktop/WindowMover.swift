import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// One movable window: identity for matching, plus a thumbnail filled in asynchronously.
struct WinItem: Identifiable {
    let id: CGWindowID
    let appName: String
    let title: String
    let bundleID: String?
    let pid: pid_t
    let frame: CGRect          // global, top-left origin (ScreenCaptureKit coords)
    var image: CGImage?
    var displayName: String { title.isEmpty ? appName : title }
}

/// Lists on-screen windows, captures thumbnails (ScreenCaptureKit), and moves a chosen window to a
/// display via the Accessibility API (the same approach `WindowLayoutStore` uses to restore layouts).
@MainActor
enum WindowMover {
    /// On-screen, normal app windows (excluding our own), sorted by app then title. No thumbnails yet.
    static func listWindows() async -> [WinItem] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return [] }
        let own = Bundle.main.bundleIdentifier
        var items: [WinItem] = []
        for w in content.windows {
            guard w.isOnScreen, let app = w.owningApplication,
                  app.bundleIdentifier != own,
                  w.frame.width > 80, w.frame.height > 60 else { continue }
            items.append(WinItem(id: w.windowID, appName: app.applicationName,
                                 title: w.title ?? "", bundleID: app.bundleIdentifier,
                                 pid: app.processID, frame: w.frame, image: nil))
        }
        items.sort { ($0.appName.lowercased(), $0.title) < ($1.appName.lowercased(), $1.title) }
        return items
    }

    /// Capture a thumbnail per item (sequentially, so they can pop in progressively via `onEach`).
    static func fillThumbnails(_ items: [WinItem],
                               onEach: @MainActor @escaping (CGWindowID, CGImage?) -> Void) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return }
        var byID: [CGWindowID: SCWindow] = [:]
        for w in content.windows { byID[w.windowID] = w }
        for item in items {
            guard let scw = byID[item.id] else { onEach(item.id, nil); continue }
            let image = await captureImage(scw)
            onEach(item.id, image)
        }
    }

    private static func captureImage(_ window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        let maxDim: CGFloat = 480
        let aspect = window.frame.width / max(1, window.frame.height)
        if aspect >= 1 { cfg.width = Int(maxDim); cfg.height = max(1, Int(maxDim / aspect)) }
        else { cfg.height = Int(maxDim); cfg.width = max(1, Int(maxDim * aspect)) }
        cfg.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    // MARK: Move

    /// Move `item`'s window to `displayID`. When `fill`, also resize it to fill that display.
    /// Returns false if the AX window couldn't be found or set.
    @discardableResult
    static func move(_ item: WinItem, toDisplay displayID: CGDirectDisplayID, fill: Bool) -> Bool {
        let bounds = CGDisplayBounds(displayID)
        let axApp = AXUIElementCreateApplication(item.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], let win = bestMatch(windows, item: item) else {
            return false
        }
        var pos = bounds.origin
        let movedPos = setAX(win, kAXPositionAttribute, .cgPoint, &pos)
        if fill {
            var size = bounds.size
            setAX(win, kAXSizeAttribute, .cgSize, &size)
            setAX(win, kAXPositionAttribute, .cgPoint, &pos) // re-apply: apps clamp pos before resize
        }
        return movedPos
    }

    /// Pick the AX window for `item`: prefer an exact title match, then the nearest frame.
    private static func bestMatch(_ windows: [AXUIElement], item: WinItem) -> AXUIElement? {
        let titled = item.title.isEmpty ? [] : windows.filter { axTitle($0) == item.title }
        let pool = titled.isEmpty ? windows : titled
        return pool.min { frameDistance(axFrame($0), item.frame) < frameDistance(axFrame($1), item.frame) }
    }

    private static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.minX - b.minX, dy = a.minY - b.minY
        return dx * dx + dy * dy
    }

    private static func axTitle(_ window: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        return (value as? String) ?? ""
    }

    private static func axFrame(_ window: AXUIElement) -> CGRect {
        var pv: CFTypeRef?, sv: CFTypeRef?
        var origin = CGPoint.zero, size = CGSize.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pv) == .success {
            AXValueGetValue(pv as! AXValue, .cgPoint, &origin)
        }
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sv) == .success {
            AXValueGetValue(sv as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    private static func setAX<T>(_ window: AXUIElement, _ attribute: String,
                                 _ type: AXValueType, _ value: inout T) -> Bool {
        guard let axValue = AXValueCreate(type, &value) else { return false }
        return AXUIElementSetAttributeValue(window, attribute as CFString, axValue) == .success
    }
}

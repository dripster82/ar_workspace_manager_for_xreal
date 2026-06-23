import AppKit
import ApplicationServices
import CoreGraphics

/// One captured window placement: which app/window it was, which tracked screen it sat on, and
/// its frame relative to that screen's origin (so it survives the displays being recreated with
/// new IDs on the next AR session, or even across reboots).
struct SavedWindow: Codable {
    var bundleID: String
    var title: String
    /// "v:<configUUID>" for a virtual screen, "p:<displayUUID>" for a physical monitor.
    var screenKey: String
    var x: Double   // top-left, relative to the screen's display origin
    var y: Double
    var w: Double
    var h: Double
}

/// What to do with a saved window layout when AR starts.
enum WindowRestoreMode: String, CaseIterable, Identifiable {
    case ask        // prompt each time
    case always     // restore silently
    case never      // ignore saved layouts
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ask: return "Always ask"
        case .always: return "Always restore"
        case .never: return "Never restore"
        }
    }
}

/// Records the on-screen window layout when AR stops and replays it (via the Accessibility API)
/// when AR starts, so apps return to the screen/position/size they were on. Persisted per
/// workspace to JSON in Application Support.
@MainActor
final class WindowLayoutStore {
    private let fileURL: URL
    /// workspace-id string → saved windows.
    private var saved: [String: [SavedWindow]] = [:]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AR Workspace Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("window-layouts.json")
        load()
    }

    func hasLayout(for workspaceID: UUID) -> Bool {
        !(saved[workspaceID.uuidString]?.isEmpty ?? true)
    }

    func count(for workspaceID: UUID) -> Int {
        saved[workspaceID.uuidString]?.count ?? 0
    }

    // MARK: Snapshot (on AR stop)

    /// Capture the current on-screen windows that fall on any tracked display. `displays` maps a
    /// live display id to its stable screen key. Call BEFORE tearing down the virtual displays —
    /// once they're destroyed macOS has already scattered their windows.
    func snapshot(workspaceID: UUID, displays: [(id: CGDirectDisplayID, key: String)]) {
        guard !displays.isEmpty else { return }
        let bounds = displays.map { (key: $0.key, rect: CGDisplayBounds($0.id)) }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }

        let ownBundle = Bundle.main.bundleIdentifier
        var records: [SavedWindow] = []
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width > 1, frame.height > 1,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier, bundleID != ownBundle else { continue }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard let match = bounds.first(where: { $0.rect.contains(center) }) else { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            records.append(SavedWindow(
                bundleID: bundleID, title: title, screenKey: match.key,
                x: Double(frame.minX - match.rect.minX), y: Double(frame.minY - match.rect.minY),
                w: Double(frame.width), h: Double(frame.height)))
        }
        saved[workspaceID.uuidString] = records
        save()
    }

    // MARK: Restore (on AR start)

    /// Move/resize running apps' windows back to their saved screens. `resolve` turns a stored
    /// screen key into the current display id (nil if that screen isn't present this session).
    /// Returns the number of windows successfully repositioned.
    @discardableResult
    func restore(workspaceID: UUID, resolve: (String) -> CGDirectDisplayID?) -> Int {
        let windows = saved[workspaceID.uuidString] ?? []
        guard !windows.isEmpty else { return 0 }

        // Group by app so we enumerate each app's AX windows once.
        var byApp: [String: [SavedWindow]] = [:]
        for w in windows { byApp[w.bundleID, default: []].append(w) }

        var restored = 0
        for (bundleID, list) in byApp {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let axWindows = value as? [AXUIElement] else { continue }

            var used = Set<Int>()
            for saved in list {
                // Prefer an exact title match; fall back to the next unused window in order.
                let idx = axWindows.indices.first { !used.contains($0) && axTitle(axWindows[$0]) == saved.title }
                    ?? axWindows.indices.first { !used.contains($0) }
                guard let i = idx, let displayID = resolve(saved.screenKey) else { continue }
                used.insert(i)
                let origin = CGDisplayBounds(displayID).origin
                var pos = CGPoint(x: origin.x + saved.x, y: origin.y + saved.y)
                var size = CGSize(width: saved.w, height: saved.h)
                set(axWindows[i], attribute: kAXPositionAttribute, type: .cgPoint, value: &pos)
                set(axWindows[i], attribute: kAXSizeAttribute, type: .cgSize, value: &size)
                restored += 1
            }
        }
        return restored
    }

    private func axTitle(_ window: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        return (value as? String) ?? ""
    }

    private func set<T>(_ window: AXUIElement, attribute: String, type: AXValueType, value: inout T) {
        guard let axValue = AXValueCreate(type, &value) else { return }
        AXUIElementSetAttributeValue(window, attribute as CFString, axValue)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [SavedWindow]].self, from: data) else { return }
        saved = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

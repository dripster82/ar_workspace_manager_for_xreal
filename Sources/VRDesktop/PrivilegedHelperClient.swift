import Foundation
import PrivilegedHelperShared
import ServiceManagement

/// App-side wrapper around the privileged helper daemon: registers it via `SMAppService`, opens an
/// XPC connection, and forwards profile-removal requests. Used as the elevation fallback when a
/// direct delete in the (root-owned) ColorSync Displays folder is denied — see
/// `SystemHealth.removeDisplayProfiles`.
@MainActor
final class PrivilegedHelperClient {
    static let shared = PrivilegedHelperClient()
    private init() {}

    private var connection: NSXPCConnection?

    private var service: SMAppService { SMAppService.daemon(plistName: HelperConstants.daemonPlistName) }

    /// Whether the daemon is registered and enabled. If it needs first-time approval, this opens the
    /// Login Items pane so the user can allow it, and returns false for now.
    @discardableResult
    func ensureRegistered() -> Bool {
        switch service.status {
        case .enabled:
            return true
        case .requiresApproval:
            NSLog("PrivilegedHelperClient: daemon requires approval — opening Login Items")
            SMAppService.openSystemSettingsLoginItems()
            return false
        case .notRegistered, .notFound:
            do {
                try service.register()
                let ok = service.status == .enabled
                if !ok { SMAppService.openSystemSettingsLoginItems() }
                return ok
            } catch {
                NSLog("PrivilegedHelperClient: register failed: \(error.localizedDescription)")
                return false
            }
        @unknown default:
            return false
        }
    }

    /// After a self-update the bundled helper binary + plist change. If the daemon was already
    /// registered, re-register so the installed daemon matches the new bundle; if it was never
    /// registered (lazy), do nothing — it'll pick up the new bundle when first needed.
    func refreshAfterUpdateIfRegistered() {
        guard service.status == .enabled else { return }
        do { try service.register() } catch {
            NSLog("PrivilegedHelperClient: post-update re-register failed: \(error.localizedDescription)")
        }
    }

    /// Register if needed, then unregister — exposed for a future "remove helper" affordance.
    func unregister() {
        try? service.unregister()
        connection?.invalidate()
        connection = nil
    }

    private func proxy(_ onError: @escaping (Error) -> Void) -> HelperProtocol? {
        let conn: NSXPCConnection
        if let existing = connection {
            conn = existing
        } else {
            conn = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            conn.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            conn.interruptionHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            conn.resume()
            connection = conn
        }
        return conn.remoteObjectProxyWithErrorHandler(onError) as? HelperProtocol
    }

    /// Ask the helper to delete the orphaned ColorSync profiles for these display UUIDs. `completion`
    /// receives the number removed (0 if the helper is unavailable or the user declined approval).
    func removeColorSyncProfiles(uuids: [String], completion: @escaping (Int) -> Void) {
        guard !uuids.isEmpty else { completion(0); return }
        guard ensureRegistered() else { completion(0); return }
        guard let proxy = proxy({ error in
            NSLog("PrivilegedHelperClient: XPC error: \(error.localizedDescription)")
            completion(0)
        }) else { completion(0); return }
        proxy.removeColorSyncProfiles(uuids: uuids) { count, errString in
            if let errString { NSLog("PrivilegedHelperClient: helper error: \(errString)") }
            completion(count)
        }
    }
}

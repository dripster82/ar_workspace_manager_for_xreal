import Foundation
import PrivilegedHelperShared

/// The actual privileged work. Deliberately minimal and self-constraining: it only ever removes
/// `*-<uuid>.icc` files from the fixed system Displays folder, and only for caller-supplied strings
/// that parse as real UUIDs. The caller cannot supply a path, a wildcard, or a `..` escape.
final class HelperService: NSObject, HelperProtocol {
    private let profilesDir = "/Library/ColorSync/Profiles/Displays"

    func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperConstants.version)
    }

    func removeColorSyncProfiles(uuids: [String], withReply reply: @escaping (Int, String?) -> Void) {
        let validUUIDs = uuids.filter { UUID(uuidString: $0) != nil }
        guard !validUUIDs.isEmpty else { reply(0, "no well-formed UUIDs supplied"); return }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: profilesDir) else {
            reply(0, "cannot read \(profilesDir)")
            return
        }
        var removed = 0
        for uuid in validUUIDs {
            let suffix = "-\(uuid).icc".lowercased()
            for name in entries where name.lowercased().hasSuffix(suffix) {
                let path = "\(profilesDir)/\(name)"
                if (try? fm.removeItem(atPath: path)) != nil { removed += 1 }
            }
        }
        NSLog("VRDesktopHelper: removed \(removed) ColorSync profile(s) for \(validUUIDs.count) UUID(s)")
        reply(removed, nil)
    }

    /// Kill the two ColorSync daemons so launchd relaunches them clean. The process names are fixed
    /// constants here — never derived from caller input — so this can only ever target these two
    /// system daemons. `killall` exits non-zero only if neither was running (already gone), which we
    /// still treat as success since the post-condition (no wedged daemon) holds.
    func bounceColorSyncDaemons(withReply reply: @escaping (Bool, String?) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        // SIGKILL (-9): a daemon pegged in a tight loop can ignore the default SIGTERM, so force it.
        p.arguments = ["-9", "colorsyncd", "colorsync.displayservices"]
        do {
            try p.run()
            p.waitUntilExit()
            NSLog("VRDesktopHelper: bounced ColorSync daemons (killall status \(p.terminationStatus))")
            reply(true, nil)
        } catch {
            NSLog("VRDesktopHelper: bounce failed: \(error.localizedDescription)")
            reply(false, error.localizedDescription)
        }
    }
}

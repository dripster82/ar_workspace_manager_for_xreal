import Foundation

/// Constants shared between the VR Desktop app and its privileged helper daemon.
public enum HelperConstants {
    /// Mach service the daemon vends and the app connects to (must match the LaunchDaemon plist).
    public static let machServiceName = "uk.co.ketelle.ar.workspace.manager.helper"
    /// LaunchDaemon plist filename in `Contents/Library/LaunchDaemons/`, passed to `SMAppService`.
    public static let daemonPlistName = "uk.co.ketelle.ar.workspace.manager.helper.plist"
    /// The main app's bundle identifier — the helper requires the connecting client to be this.
    public static let appBundleID = "uk.co.ketelle.ar.workspace.manager"

    /// Apple Developer **Team ID** (Paul Ketelle, read from the issued signing cert). The helper
    /// verifies the XPC client's code signature is anchored to Apple AND signed by this team, so only
    /// the real, notarised app can ask root to delete files. Release builds reject every client if
    /// this is wrong/unset (fail-closed); debug builds skip the check (see ClientValidator).
    public static let teamID = "834D8P4J32"

    /// Bumped manually; lets the app confirm the installed daemon matches the expected build.
    /// v2: added `bounceColorSyncDaemons`.
    public static let version = "2"
}

/// XPC interface the helper exposes. Kept deliberately narrow: the only privileged operation is
/// removing macOS-generated per-display ColorSync profiles, and the helper — not the caller — decides
/// which files that touches (it only ever deletes `<name>-<uuid>.icc` in the system Displays folder
/// for UUIDs the caller names). The app can never make it delete an arbitrary path.
@objc public protocol HelperProtocol {
    /// Delete every `*-<uuid>.icc` in `/Library/ColorSync/Profiles/Displays` for each well-formed
    /// UUID in `uuids`. Replies with the count removed and an optional error string.
    func removeColorSyncProfiles(uuids: [String], withReply reply: @escaping (Int, String?) -> Void)

    /// Restart the root-owned ColorSync daemons (`colorsyncd`, `colorsync.displayservices`) by
    /// killing them — launchd relaunches them clean. Used by the app's watchdog to break the
    /// `colorsync.displayservices` runaway when it pins the CPU. Both daemons run as root, so this
    /// is the only way the app can bounce them. Replies with success and an optional error string.
    func bounceColorSyncDaemons(withReply reply: @escaping (Bool, String?) -> Void)

    /// Returns the helper's `HelperConstants.version`, so the app can detect a stale installed daemon.
    func getVersion(withReply reply: @escaping (String) -> Void)
}

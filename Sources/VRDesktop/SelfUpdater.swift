import Foundation
import PrivilegedHelperShared

/// In-app updater for the notarised, Developer-ID-signed app: downloads a release `.dmg`, **verifies
/// it is our genuine build** (signature intact + signed by our Team ID + Gatekeeper-accepted i.e.
/// notarised), stages a copy, then launches a small detached shell helper that waits for this process
/// to quit, swaps the running `.app` bundle, and relaunches.
///
/// The verification step is the security boundary: we never overwrite the running app with downloaded
/// bytes that don't pass all three checks, so this cannot be turned into a malware-delivery channel.
enum SelfUpdater {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Run the full update. Returns once the swap helper is armed (the caller should then quit so the
    /// helper can replace the bundle). Throws — leaving the installed app untouched — on any failure.
    static func installUpdate(from dmgURL: URL,
                              teamID: String = HelperConstants.teamID,
                              status: @MainActor @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("arwm-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        await status("Downloading update…")
        let (downloaded, resp) = try await URLSession.shared.download(from: dmgURL)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure(message: "Download failed (HTTP \(http.statusCode)).")
        }
        let dmg = work.appendingPathComponent("update.dmg")
        try fm.moveItem(at: downloaded, to: dmg)

        // The rest is blocking shell work (hdiutil/codesign/spctl/ditto) — keep it off the main thread.
        let destBundle = Bundle.main.bundlePath
        try await Task.detached(priority: .userInitiated) {
            try performInstall(dmg: dmg.path, work: work.path, destBundle: destBundle,
                               teamID: teamID, status: status)
        }.value
    }

    // MARK: - Implementation (background thread)

    private static func performInstall(dmg: String, work: String, destBundle: String,
                                       teamID: String, status: @MainActor @escaping (String) -> Void) throws {
        let fm = FileManager.default
        func say(_ s: String) { Task { @MainActor in status(s) } }

        // Fail BEFORE we touch anything if we can't write where the app lives (don't quit-then-fail).
        let installDir = (destBundle as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: installDir) else {
            throw Failure(message: "Can't write to \(installDir). Move the app to a folder you own (e.g. /Applications) and try again.")
        }

        say("Mounting…")
        let mount = "\(work)/mnt"
        try fm.createDirectory(atPath: mount, withIntermediateDirectories: true)
        try sh("/usr/bin/hdiutil", ["attach", dmg, "-nobrowse", "-readonly", "-mountpoint", mount])
        defer { _ = try? sh("/usr/bin/hdiutil", ["detach", mount, "-force"]) }

        guard let appName = (try? fm.contentsOfDirectory(atPath: mount))?.first(where: { $0.hasSuffix(".app") }) else {
            throw Failure(message: "No application found in the disk image.")
        }
        let mountedApp = "\(mount)/\(appName)"

        say("Verifying signature…")
        try verify(app: mountedApp, teamID: teamID)

        // Copy out of the read-only image, re-verify, then drop quarantine (legitimate post-verify).
        say("Preparing…")
        let staged = "\(work)/\(appName)"
        try sh("/usr/bin/ditto", [mountedApp, staged])
        try verify(app: staged, teamID: teamID)
        _ = try? sh("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged])

        // Arm the swap+relaunch helper. It waits for our PID to exit, swaps the bundle atomically
        // (ditto to a sibling on the same volume, then rename), relaunches, and cleans up.
        say("Installing…")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /usr/bin/ditto "\(staged)" "\(destBundle).new" || exit 1
        /bin/rm -rf "\(destBundle).bak"
        /bin/mv "\(destBundle)" "\(destBundle).bak" || exit 1
        if ! /bin/mv "\(destBundle).new" "\(destBundle)"; then
          /bin/mv "\(destBundle).bak" "\(destBundle)"   # roll back on failure
          exit 1
        fi
        /bin/rm -rf "\(destBundle).bak"
        /usr/bin/xattr -dr com.apple.quarantine "\(destBundle)" 2>/dev/null
        /usr/bin/open "\(destBundle)"
        /bin/rm -rf "\(work)"
        """
        let scriptPath = "\(work)/swap.sh"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try sh("/bin/chmod", ["+x", scriptPath])

        say("Restarting…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptPath]
        try p.run()   // detached — we deliberately do NOT wait; the caller now quits
    }

    /// The three-part trust check. Any failure throws and aborts the update.
    private static func verify(app: String, teamID: String) throws {
        // 1. The signature is intact and covers the whole bundle (incl. the nested helper).
        try sh("/usr/bin/codesign", ["--verify", "--deep", "--strict", app])
        // 2. It's a Developer ID build signed by OUR team (not just any valid signature).
        let info = try sh("/usr/bin/codesign", ["-dv", "--verbose=4", app])  // details print on stderr (merged below)
        guard info.contains("TeamIdentifier=\(teamID)") else {
            throw Failure(message: "Update isn't signed by the expected developer (team \(teamID)).")
        }
        guard info.contains("Authority=Developer ID Application") else {
            throw Failure(message: "Update isn't a Developer ID build.")
        }
        // 3. Gatekeeper accepts it — i.e. it's notarised.
        try sh("/usr/sbin/spctl", ["--assess", "--type", "exec", app])
    }

    /// Run a tool, capturing stdout+stderr; throw with the output if it exits non-zero.
    @discardableResult
    private static func sh(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let tool = (launchPath as NSString).lastPathComponent
            throw Failure(message: "\(tool) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return out
    }
}

import Foundation

/// Append-only session log for virtual-display churn + crash forensics:
/// `~/Library/Application Support/AR Workspace Manager/display-churn.log`.
///
/// One `session-start` line per app launch (tagged with the BOOT session UUID so app runs can be
/// grouped per boot — the ColorSync self-loop's state lives at boot scope), a `churn` line whenever
/// the counters change, and a `session-end` line on clean quit. On launch it also works out how the
/// PREVIOUS session ended: a clean-exit marker is cleared at start and set on quit, and the
/// WindowServer PID is recorded so "app died" can be told apart from "WindowServer crashed and took
/// the whole login session down" (the ColorSync-runaway failure mode seen 2026-07-01/02).
enum ChurnLog {
    /// How the previous app session ended, derived at launch.
    enum PreviousExit {
        case cleanQuit
        case appCrash                 // app died but WindowServer survived (same boot, same WS pid)
        case windowServerCrash        // same boot but WindowServer restarted → session was reset
        case rebootOrPowerLoss        // different boot with no clean exit
        case unknown                  // first run / no marker

        var label: String {
            switch self {
            case .cleanQuit: return "clean quit"
            case .appCrash: return "app crash/force-quit (WindowServer survived)"
            case .windowServerCrash: return "WindowServer CRASH — login session was reset"
            case .rebootOrPowerLoss: return "reboot or power loss while running"
            case .unknown: return "unknown (first run)"
            }
        }
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AR Workspace Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("display-churn.log")
    }

    /// The kernel's boot-session UUID — matches the `bootSessionUUID` field in macOS crash reports,
    /// so log lines can be correlated with WindowServer stackshots directly.
    static func bootSessionUUID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }

    /// Current WindowServer PID (0 if not found). A changed PID within the same boot means
    /// WindowServer was restarted — i.e. the login session was reset.
    static func windowServerPID() -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "WindowServer"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return 0 }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Int32(out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? "") ?? 0
    }

    /// Classify how the previous session ended, then arm the marker for THIS session (clean-exit
    /// false until `markCleanExit()` runs at quit). Call once at launch, before anything else writes.
    static func detectPreviousExit() -> PreviousExit {
        let d = UserDefaults.standard
        defer {
            d.set(false, forKey: "churn.cleanExit")
            d.set(bootSessionUUID(), forKey: "churn.bootUUID")
            d.set(Int(windowServerPID()), forKey: "churn.wsPID")
        }
        guard d.object(forKey: "churn.cleanExit") != nil else { return .unknown }
        if d.bool(forKey: "churn.cleanExit") { return .cleanQuit }
        let sameBoot = d.string(forKey: "churn.bootUUID") == bootSessionUUID()
        guard sameBoot else { return .rebootOrPowerLoss }
        return Int32(d.integer(forKey: "churn.wsPID")) == windowServerPID() ? .appCrash : .windowServerCrash
    }

    /// Record a clean shutdown (call from applicationWillTerminate).
    static func markCleanExit() { UserDefaults.standard.set(true, forKey: "churn.cleanExit") }

    /// Append a timestamped line to the churn log.
    static func append(_ message: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }
}

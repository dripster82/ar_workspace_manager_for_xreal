import ColorSync
import CoreGraphics
import Foundation

/// One monitored process's summed %CPU.
struct ProcessSample: Identifiable, Sendable {
    let name: String
    let cpu: Double
    var id: String { name }
}

/// Cheap system-health probes for the Diagnostics page: CPU of known problem processes (the
/// ColorSync runaway, WindowServer, Sophos), and counts of accumulated ColorSync display profiles
/// and saved WindowServer display configs (both of which, when excessive, drive the runaway).
enum SystemHealth {
    /// Process names we watch. Matching is case-insensitive substring, summed per name (so all the
    /// Sophos helpers roll up into one figure).
    static let watchedProcesses = ["colorsync.displayservices", "colorsyncd", "WindowServer", "Sophos"]

    static func processCPU(matching names: [String]) -> [ProcessSample] {
        let lines = runPS().split(separator: "\n")
        var totals: [String: Double] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let sp = trimmed.firstIndex(of: " "), let cpu = Double(trimmed[..<sp]) else { continue }
            let comm = trimmed[trimmed.index(after: sp)...].trimmingCharacters(in: .whitespaces).lowercased()
            for name in names where comm.contains(name.lowercased()) {
                totals[name, default: 0] += cpu
            }
        }
        return names.map { ProcessSample(name: $0, cpu: totals[$0] ?? 0) }
    }

    private static func runPS() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pcpu,comm"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Number of per-display ICC profiles macOS has accumulated. Excessive = registry bloat.
    static func colorSyncDisplayProfileCount() -> Int {
        let dir = "/Library/ColorSync/Profiles/Displays"
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return all.filter { $0.hasSuffix(".icc") }.count
    }

    /// Number of saved WindowServer display arrangements. Excessive = the displays-plist bloat that
    /// makes ColorSync re-parse a huge plist (see Docs/ColorSync-AirII-investigation.md).
    static func displayConfigCount() -> Int {
        let byHost = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/ByHost", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
                at: byHost, includingPropertiesForKeys: nil),
              let file = files.first(where: {
                  // Extension must be exactly "plist": the clear leaves a `.plist.bak` backup
                  // alongside, which also matches the prefix — pre-fix, the count read the BACKUP
                  // and kept showing the old number after a successful clear + reboot.
                  $0.lastPathComponent.hasPrefix("com.apple.windowserver.displays.")
                      && $0.pathExtension == "plist" }),
              let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any],
              let sets = plist["DisplaySets"] as? [String: Any],
              let configs = sets["Configs"] as? [Any] else { return 0 }
        return configs.count
    }

    /// Path to the system folder where macOS auto-generates one ICC profile per display, named
    /// `<display name>-<CGDisplay UUID>.icc`. Admin-writable (group `wheel`), so members of `admin`
    /// can prune it without elevation; on a standard account the removes below silently no-op.
    private static let displayProfilesDir = "/Library/ColorSync/Profiles/Displays"

    /// The CGDisplay UUID string macOS uses to key a display's ColorSync profile, or nil.
    static func displayUUID(_ id: CGDirectDisplayID) -> String? {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, ref) as String?
    }

    /// UUID strings of every display currently online (built-in, externals, glasses, and any live
    /// virtual displays). The orphan sweep keeps these and removes everything else. Uppercased to
    /// match the casing macOS uses in the generated filenames.
    static func onlineDisplayUUIDs() -> Set<String> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)).compactMap { displayUUID($0)?.uppercased() })
    }

    /// Extract the trailing CGDisplay UUID from a macOS-generated profile filename
    /// (`<display name>-<UUID>.icc`), or nil if the name doesn't end in a well-formed UUID.
    private static func uuid(fromProfileName name: String) -> String? {
        guard name.hasSuffix(".icc") else { return nil }
        let base = name.dropLast(4)              // strip ".icc"
        guard base.count >= 36 else { return nil }
        let candidate = String(base.suffix(36))
        return UUID(uuidString: candidate) != nil ? candidate.uppercased() : nil
    }

    /// Delete every generated per-display profile whose UUID is **not currently online** — i.e. the
    /// orphans left behind when virtual displays are torn down (app quit/crash, AR stop) or by the
    /// Air 2's display UUID churning between sessions. These accumulate and bloat the ColorSync
    /// registry, whose repeated re-parse drives the `colorsync.displayservices` runaway (see
    /// Docs/ColorSync-AirII-investigation.md). Online displays — built-in, externals, the live
    /// glasses, in-use virtuals — are always kept; macOS regenerates any profile it actually needs.
    /// Safe to call on launch, on AR stop, and from the watchdog. Returns the count removed directly.
    @discardableResult
    static func sweepOrphanProfiles() -> Int {
        let fm = FileManager.default
        let live = onlineDisplayUUIDs()
        let all = (try? fm.contentsOfDirectory(atPath: displayProfilesDir)) ?? []
        let orphans = all.compactMap { uuid(fromProfileName: $0) }.filter { !live.contains($0) }
        guard !orphans.isEmpty else { return 0 }
        return removeDisplayProfiles(uuids: Array(Set(orphans)))
    }

    /// Remove the per-display ColorSync profile(s) macOS generated for `uuid`. Called when a virtual
    /// display is permanently removed from a workspace so its now-orphaned profile doesn't linger and
    /// bloat the ColorSync registry (the re-parse of which drives the colorsync.displayservices
    /// runaway — see Docs/ColorSync-AirII-investigation.md). Matching on the UUID suffix also sweeps
    /// up stale name-variants for the same slot (e.g. left behind by a rename).
    ///
    /// The folder is group-`wheel`-writable, so admin accounts delete directly with no prompt. If a
    /// direct remove is denied (standard account, or a locked-down folder), the leftovers are handed
    /// to the privileged helper daemon (`PrivilegedHelperClient`), which removes them as root after
    /// verifying our code signature. Returns the count removed *directly* (the privileged path is
    /// async). Passing the UUID — not paths — means the helper, not us, decides which files it touches.
    @discardableResult
    static func removeDisplayProfiles(uuid: String) -> Int {
        removeDisplayProfiles(uuids: [uuid])
    }

    /// Batch form of `removeDisplayProfiles(uuid:)`: removes the `*-<uuid>.icc` for every UUID,
    /// deleting directly where permitted and handing any denied UUIDs to the privileged helper in a
    /// single XPC call (instead of one per UUID). Returns the count removed *directly*.
    @discardableResult
    static func removeDisplayProfiles(uuids: [String]) -> Int {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(atPath: displayProfilesDir)) ?? []
        var removed = 0
        var denied: [String] = []
        for uuid in uuids {
            let suffix = "-\(uuid).icc".lowercased()
            let matches = all.filter { $0.lowercased().hasSuffix(suffix) }
                .map { "\(displayProfilesDir)/\($0)" }
            var anyDenied = false
            for path in matches {
                do { try fm.removeItem(atPath: path); removed += 1 }
                catch { if fm.fileExists(atPath: path) { anyDenied = true } }
            }
            if anyDenied { denied.append(uuid) }
        }
        if removed > 0 { NSLog("SystemHealth: removed \(removed) ColorSync profile(s)") }
        if !denied.isEmpty {
            Task { @MainActor in
                PrivilegedHelperClient.shared.removeColorSyncProfiles(uuids: denied) { n in
                    if n > 0 { NSLog("SystemHealth: removed \(n) ColorSync profile(s) via privileged helper") }
                }
            }
        }
        return removed
    }

    /// Delete the per-host WindowServer display-arrangement plist(s)
    /// (`com.apple.windowserver.displays.*.plist`), backing each up alongside as `.bak` first. These
    /// accumulate one saved arrangement per distinct display-set combination and, once huge, force
    /// ColorSync to re-parse a giant plist on every display query (the other half of the runaway).
    /// The file lives in the user's `ByHost` prefs so no elevation is needed; cfprefsd caches it,
    /// so this only takes full effect after a logout/WindowServer restart — the caller should tell
    /// the user. Returns the number of plists removed.
    @discardableResult
    static func clearSavedDisplayConfigs() -> Int {
        let fm = FileManager.default
        let byHost = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/ByHost", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: byHost, includingPropertiesForKeys: nil)
        else { return 0 }
        var removed = 0
        // Full clear: the plist AND any .bak left by earlier clears (we used to keep a backup, but
        // a lingering 50-config .bak caused "still shows 50" confusion, and WindowServer rebuilds a
        // fresh arrangement on the next reboot anyway — worst case you re-drag your monitor layout).
        for f in files where f.lastPathComponent.hasPrefix("com.apple.windowserver.displays.") {
            if (try? fm.removeItem(at: f)) != nil, f.pathExtension == "plist" { removed += 1 }
        }
        if removed > 0 { NSLog("SystemHealth: cleared \(removed) saved display-config plist(s)") }
        return removed
    }
}

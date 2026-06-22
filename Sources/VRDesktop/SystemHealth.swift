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
                  $0.lastPathComponent.hasPrefix("com.apple.windowserver.displays.") }),
              let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any],
              let sets = plist["DisplaySets"] as? [String: Any],
              let configs = sets["Configs"] as? [Any] else { return 0 }
        return configs.count
    }
}

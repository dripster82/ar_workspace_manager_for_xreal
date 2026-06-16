import Darwin
import Foundation

/// Lightweight system-load sampler for correlating render stalls with machine load. Cheap
/// in-process metrics (load average, thermal state) plus a best-effort `ps` for the top CPU
/// processes (so we can see whether Sophos / colorsync / WindowServer are hot during a janky
/// session). Call off the main thread — the `ps` spawn shouldn't touch the render path.
enum SystemLoad {
    static func sample() -> String {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "?"
        }
        return String(format: "load=%.2f/%.2f/%.2f thermal=%@ %@",
                      loads[0], loads[1], loads[2], thermal, topProcesses())
    }

    /// Top CPU processes via `ps`, plus a summed Sophos figure (the prime suspect). Returns a
    /// short marker string on failure (e.g. if the hardened runtime blocks the spawn).
    private static func topProcesses() -> String {
        guard let out = run("/bin/ps", ["-Aceo", "pcpu,comm", "-r"]) else { return "(ps unavailable)" }
        var top: [String] = []
        var sophos = 0.0, windowServer = 0.0, colorsync = 0.0
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let cpu = Double(parts[0]) else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            let lower = name.lowercased()
            if lower.contains("sophos") { sophos += cpu }
            if lower.contains("windowserver") { windowServer += cpu }
            if lower.contains("colorsync") { colorsync += cpu }
            if top.count < 6 { top.append("\(name):\(Int(cpu))") }
        }
        return String(format: "sophos=%.0f%% ws=%.0f%% colorsync=%.0f%% top=[%@]",
                      sophos, windowServer, colorsync, top.joined(separator: " "))
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

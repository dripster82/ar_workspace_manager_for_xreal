import Foundation

/// Lightweight file logger for troubleshooting. Writes timestamped lines to
/// ~/Library/Application Support/VRDesktop/debug.log when enabled.
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()

    let fileURL: URL
    private let queue = DispatchQueue(label: "debug.log")
    private var handle: FileHandle?
    private var enabled = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VRDesktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("debug.log")
    }

    func setEnabled(_ on: Bool) {
        queue.async {
            guard on != self.enabled else { return }
            if on {
                if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                    FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
                }
                self.handle = try? FileHandle(forWritingTo: self.fileURL)
                self.handle?.seekToEndOfFile()
                self.enabled = true
                self.write("=== logging enabled ===")
            } else {
                self.write("=== logging disabled ===")
                try? self.handle?.close()
                self.handle = nil
                self.enabled = false
            }
        }
    }

    func log(_ message: @autoclosure @escaping () -> String) {
        queue.async {
            guard self.enabled else { return }
            self.write(message())
        }
    }

    func clear() {
        queue.async {
            try? self.handle?.close()
            try? Data().write(to: self.fileURL)
            self.handle = try? FileHandle(forWritingTo: self.fileURL)
            self.handle?.seekToEndOfFile()
            if self.enabled { self.write("=== log cleared ===") }
        }
    }

    private func write(_ message: String) {
        let line = "[\(Self.formatter.string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) { handle?.write(data) }
    }
}

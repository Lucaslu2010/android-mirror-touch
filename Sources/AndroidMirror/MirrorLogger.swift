import Foundation

enum MirrorLogger {
    private static let queue = DispatchQueue(label: "AndroidMirror.MirrorLogger", qos: .utility)
    private static let logURL: URL = {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let directory = root.appendingPathComponent(".build/android-mirror-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("embedded-scrcpy.log")
    }()
    private static var handle: FileHandle?
    private static let formatter = ISO8601DateFormatter()

    static func reset() {
        queue.sync {
            try? handle?.close()
            handle = nil
            try? Data().write(to: logURL, options: .atomic)
            handle = try? FileHandle(forWritingTo: logURL)
            writeLocked("--- Android Mirror log started ---")
        }
    }

    static func log(_ message: String) {
        queue.async {
            writeLocked(message)
        }
    }

    private static func writeLocked(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let uptime = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
        if handle == nil {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: logURL)
        }
        guard let handle else { return }
        let line = "[\(timestamp) +\(uptime)s] \(message)\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

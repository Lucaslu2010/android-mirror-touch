import Foundation

enum TouchTraceLogger {
    /// Raw HID tracing is intentionally opt-in. `getevent` shares the ADB USB
    /// transport with video and high-frequency file logging can itself create
    /// the latency/jitter that this logger is meant to diagnose.
    static let isEnabled = ProcessInfo.processInfo.environment["ANDROID_MIRROR_TOUCH_TRACE"] == "1"

    static let fileURL: URL = {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent(".build/android-mirror-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("touch-input.log")
    }()

    private static let queue = DispatchQueue(label: "AndroidMirror.TouchTrace")

    static func reset() {
        guard isEnabled else { return }
        queue.sync {
            let header = "Touch trace started \(ISO8601DateFormatter().string(from: Date()))\n"
            try? header.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        queue.async {
            let seconds = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
            let line = "[\(seconds)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}

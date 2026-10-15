import CoreGraphics
import Foundation

enum AndroidDisplayRotation: Int {
    case portrait = 0
    case landscapeRight = 1
    case portraitUpsideDown = 2
    case landscapeLeft = 3

    /// Convert active-preview coordinates into the raw natural-panel
    /// coordinates expected by Android's orientation-aware HID mapper.
    func rawHIDPoint(forPreviewX x: Double, y: Double) -> CGPoint {
        let x = min(max(x, 0), 1)
        let y = min(max(y, 0), 1)
        switch self {
        case .portrait:
            return CGPoint(x: x, y: y)
        case .landscapeRight:
            // InputReader ROTATION_90 maps raw (x,y) to (y,1-x).
            return CGPoint(x: 1 - y, y: x)
        case .portraitUpsideDown:
            return CGPoint(x: 1 - x, y: 1 - y)
        case .landscapeLeft:
            // InputReader ROTATION_270 maps raw (x,y) to (1-y,x).
            return CGPoint(x: y, y: 1 - x)
        }
    }
}

struct AndroidDevice: Identifiable, Hashable {
    let serial: String
    let model: String
    let state: String

    var id: String { serial }
    var isReady: Bool { state == "device" }

    var title: String {
        model.isEmpty ? serial : model
    }
}

enum ADBError: LocalizedError {
    case unavailable
    case commandFailed(String)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Android platform-tools was not found. Install it with Homebrew."
        case let .commandFailed(message):
            return message
        case .invalidImage:
            return "Android returned a screen frame that macOS could not decode."
        }
    }
}

struct ADBClient {
    private let executableURL: URL?

    init() {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let fromPath = environmentPath
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("adb") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }

        let knownLocations = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/Applications/Android Studio.app/Contents/sdk/platform-tools/adb"
        ].map(URL.init(fileURLWithPath:))

        executableURL = fromPath ?? knownLocations.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    func devices() throws -> [AndroidDevice] {
        let output = try run(["devices", "-l"])
        let text = String(decoding: output, as: UTF8.self)

        return text
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2 else { return nil }
                let serial = String(parts[0])
                let state = String(parts[1])
                let model = parts
                    .first(where: { $0.hasPrefix("model:") })
                    .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") }
                    ?? ""
                return AndroidDevice(serial: serial, model: model, state: state)
            }
    }

    func captureScreen(serial: String) throws -> Data {
        let data = try run(["-s", serial, "exec-out", "screencap", "-p"])
        guard !data.isEmpty else { throw ADBError.invalidImage }
        return data
    }

    func accessoryTouchEventPath(serial: String) throws -> String? {
        let text = String(decoding: try run(["-s", serial, "shell", "dumpsys", "input"]), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for index in lines.indices where lines[index].contains("Path: /dev/input/event") {
            let following = lines[index..<min(index + 18, lines.endIndex)]
            guard following.contains(where: { $0.contains("usb_accessory") }) else { continue }
            let path = lines[index]
                .split(separator: ":", maxSplits: 1)
                .dropFirst()
                .first?
                .trimmingCharacters(in: .whitespaces)
            if let path, path.hasPrefix("/dev/input/event") {
                return path
            }
        }
        return nil
    }

    /// InputReader's SurfaceOrientation is authoritative for an external HID
    /// touchscreen. WindowManager may briefly report a different value while
    /// the phone is turning, so use it only as a fallback.
    func displayRotation(serial: String) throws -> AndroidDisplayRotation? {
        let input = String(decoding: try run([
            "-s", serial, "shell",
            "dumpsys input | grep -m 1 -E 'Viewport INTERNAL: displayId=0|SurfaceOrientation|mSurfaceOrientation' || true"
        ]), as: UTF8.self)
        if let rotation = parseRotation(
            from: input,
            patterns: [
                "Viewport INTERNAL: displayId=0[^\\n]*orientation=(\\d+)",
                "SurfaceOrientation\\s*:\\s*(\\d+)",
                "mSurfaceOrientation\\s*=\\s*(\\d+)"
            ]
        ) {
            return rotation
        }

        let display = String(decoding: try run([
            "-s", serial, "shell",
            "dumpsys display | grep -m 1 -E 'DisplayViewport\\{type=INTERNAL' || true"
        ]), as: UTF8.self)
        if let rotation = parseRotation(
            from: display,
            patterns: ["DisplayViewport\\{type=INTERNAL[^\\n]*orientation=(\\d+)"]
        ) {
            return rotation
        }

        let window = String(decoding: try run([
            "-s", serial, "shell",
            "dumpsys window displays | grep -m 1 -E 'mCurrentRotation=' || true"
        ]), as: UTF8.self)
        if let rotation = parseRotation(
            from: window,
            patterns: [
                "mCurrentRotation\\s*=\\s*ROTATION_(\\d+)",
                "mCurrentRotation\\s*=\\s*(\\d+)"
            ]
        ) {
            return rotation
        }

        return nil
    }

    func run(_ arguments: [String]) throws -> Data {
        guard let executableURL else { throw ADBError.unavailable }

        let process = Process()
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let outputURL = temporaryDirectory.appendingPathComponent("android-mirror-\(UUID().uuidString).out")
        let errorURL = temporaryDirectory.appendingPathComponent("android-mirror-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let standardOutput = try FileHandle(forWritingTo: outputURL)
        let standardError = try FileHandle(forWritingTo: errorURL)
        defer {
            try? standardOutput.close()
            try? standardError.close()
        }

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw ADBError.commandFailed("Could not launch adb: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let output = try Data(contentsOf: outputURL)
        let error = try Data(contentsOf: errorURL)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ADBError.commandFailed(message.isEmpty ? "adb exited with status \(process.terminationStatus)." : message)
        }
        return output
    }

    func start(_ arguments: [String], output: Pipe? = nil) throws -> Process {
        guard let executableURL else { throw ADBError.unavailable }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        try process.run()
        return process
    }

    private func parseRotation(from text: String, patterns: [String]) -> AndroidDisplayRotation? {
        let fullRange = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: fullRange),
                  let range = Range(match.range(at: 1), in: text),
                  let value = Int(text[range]),
                  let rotation = AndroidDisplayRotation(rawValue: value) else { continue }
            return rotation
        }
        return nil
    }

}

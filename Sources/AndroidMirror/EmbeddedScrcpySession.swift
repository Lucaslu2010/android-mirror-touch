import CoreGraphics
import Darwin
import Foundation

final class EmbeddedScrcpySession {
    enum TouchAction: UInt8 {
        case down = 0
        case up = 1
        case move = 2
    }

    var onFrame: ((CGImage) -> Void)?
    var onStatus: ((String) -> Void)?
    var onAudioStatus: ((String) -> Void)?
    /// Emitted as soon as scrcpy announces a changed video surface. The model
    /// uses this as an immediate cue to refresh Android's physical rotation;
    /// waiting for the normal device-discovery pass makes touch orientation
    /// stale for seconds after the phone turns.
    var onVideoSize: ((CGSize) -> Void)?

    private let serial: String
    private let adb = ADBClient()
    private let queue = DispatchQueue(label: "AndroidMirror.EmbeddedScrcpy")
    private let controlQueue = DispatchQueue(label: "AndroidMirror.EmbeddedScrcpy.Control")
    private let audioQueue = DispatchQueue(label: "AndroidMirror.EmbeddedScrcpy.Audio", qos: .userInteractive)
    private let decoder = H264VideoDecoder()
    private let audioPlayer: PCMStreamPlayer
    private let frameLock = NSLock()
    private var pendingFrame: CGImage?
    private var isFrameDeliveryScheduled = false
    private var decodedFrameCount = 0
    private var deliveredFrameCount = 0
    private var coalescedFrameCount = 0
    private var lastFrameSummaryUptime = ProcessInfo.processInfo.systemUptime
    private var videoPacketCount = 0
    private var firstVideoPTSUs: Int64?
    private var lastVideoPTSUs: Int64?
    private var lastVideoRateSummaryUptime = ProcessInfo.processInfo.systemUptime
    private var socketDescriptor: Int32?
    private var audioSocketDescriptor: Int32?
    private var controlSocketDescriptor: Int32?
    private var serverProcess: Process?
    private var serverLogPipe: Pipe?
    private var forwardedPort: Int?
    private var isStopped = false

    init(serial: String, audioVolume: Double) {
        self.serial = serial
        self.audioPlayer = PCMStreamPlayer(volume: audioVolume)
        decoder.onFrame = { [weak self] image in self?.enqueueLatestFrame(image) }
    }

    func start() {
        MirrorLogger.log("Queueing embedded scrcpy session for \(serial)")
        queue.async { [weak self] in self?.run() }
    }

    func stop() {
        isStopped = true
        frameLock.lock()
        pendingFrame = nil
        frameLock.unlock()
        MirrorLogger.log("Stopping embedded scrcpy session")

        // `run()` occupies the session queue in a blocking recv loop. Stop
        // must therefore close the descriptors from the caller's thread;
        // queueing this cleanup behind `run()` would make it unreachable.
        if let socketDescriptor {
            shutdown(socketDescriptor, SHUT_RDWR)
            close(socketDescriptor)
            self.socketDescriptor = nil
        }
        if let audioSocketDescriptor {
            shutdown(audioSocketDescriptor, SHUT_RDWR)
            close(audioSocketDescriptor)
            self.audioSocketDescriptor = nil
        }
        audioPlayer.stop()
        if let controlSocketDescriptor {
            shutdown(controlSocketDescriptor, SHUT_RDWR)
            close(controlSocketDescriptor)
            self.controlSocketDescriptor = nil
        }
        serverProcess?.terminate()
        if let port = forwardedPort {
            DispatchQueue.global(qos: .utility).async { [adb, serial] in
                _ = try? adb.run(["-s", serial, "forward", "--remove", "tcp:\(port)"])
            }
        }
    }

    func sendTouch(
        action: TouchAction,
        normalizedX: Double,
        normalizedY: Double,
        screenSize: CGSize
    ) {
        guard screenSize.width > 0, screenSize.height > 0 else { return }
        let x = UInt32((min(max(normalizedX, 0), 1) * screenSize.width).rounded())
        let y = UInt32((min(max(normalizedY, 0), 1) * screenSize.height).rounded())
        let width = UInt16(clamping: Int(screenSize.width.rounded()))
        let height = UInt16(clamping: Int(screenSize.height.rounded()))
        let message = Self.touchMessage(
            action: action,
            x: min(x, width > 0 ? UInt32(width - 1) : 0),
            y: min(y, height > 0 ? UInt32(height - 1) : 0),
            width: width,
            height: height
        )

        controlQueue.async { [weak self] in
            guard let self, let descriptor = self.controlSocketDescriptor else { return }
            guard Self.sendAll(message, to: descriptor) else {
                self.onStatus?("The embedded touch-control socket disconnected.")
                return
            }
        }
    }

    func setAudioVolume(_ volume: Double) {
        audioPlayer.setVolume(volume)
    }

    private func run() {
        do {
            let port = Int.random(in: 28_000...38_000)
            let scid = String(format: "%08x", UInt32.random(in: 1...(UInt32.max >> 1)))
            forwardedPort = port
            MirrorLogger.log("Preparing server: scid=\(scid), port=\(port)")
            _ = try adb.run(["-s", serial, "push", serverPath.path, "/data/local/tmp/android-mirror-scrcpy-server.jar"])
            _ = try adb.run(["-s", serial, "forward", "tcp:\(port)", "localabstract:scrcpy_\(scid)"])
            MirrorLogger.log("ADB forward established")

            let serverLogPipe = Pipe()
            self.serverLogPipe = serverLogPipe
            let serverArguments = [
                "-s", serial,
                "shell",
                "CLASSPATH=/data/local/tmp/android-mirror-scrcpy-server.jar",
                "app_process", "/", "com.genymobile.scrcpy.Server", "4.0",
                "scid=\(scid)",
                "log_level=debug",
                // Request the normal 60fps capture ceiling explicitly.  The
                // Android encoder still decides the actual rate based on the
                // device display/content (scrcpy's rate is variable).
                "max_fps=60",
                // Keep the MediaCodec request explicit for devices whose
                // vendor encoder otherwise defaults to a lower operating point.
                "video_codec_options=frame-rate=60",
                "video_bit_rate=8000000",
                // RAW PCM avoids an extra codec dependency on macOS. scrcpy
                // sends 48 kHz stereo signed-16-bit samples in framed packets.
                "audio=true",
                "audio_codec=raw",
                "control=false",
                "tunnel_forward=true"
            ]
            serverProcess = try adb.start(serverArguments, output: serverLogPipe)
            MirrorLogger.log("Embedded server process started")
            serverLogPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let output = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.isEmpty {
                    MirrorLogger.log("Server: \(output)")
                }
            }
            serverProcess?.terminationHandler = { [weak self] process in
                let data = serverLogPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, !self.isStopped else { return }
                let message = output.isEmpty
                    ? "Embedded scrcpy server stopped (status \(process.terminationStatus))."
                    : "Embedded scrcpy server: \(output)"
                self.onStatus?(message)
                MirrorLogger.log(message)
            }

            let socketDescriptor = try connectToVideoSocket(port: port)
            self.socketDescriptor = socketDescriptor
            MirrorLogger.log("Connected to local video socket")
            startAudioStream(port: port)

            let deviceNameData = try readExactly(64, from: socketDescriptor)
            let deviceName = String(decoding: deviceNameData.prefix { $0 != 0 }, as: UTF8.self)
            MirrorLogger.log("Connected device metadata: \(deviceName)")
            let codec = try readExactly(4, from: socketDescriptor)
            guard codec == Data([0x68, 0x32, 0x36, 0x34]) else {
                throw ADBError.commandFailed("The embedded stream is not H.264.")
            }
            MirrorLogger.log("Received H.264 stream header")
            onStatus?("Streaming with embedded H.264 renderer")

            while !isStopped {
                let header = try readExactly(12, from: socketDescriptor)
                // In scrcpy 4.0, the high bit marks a session packet carrying
                // the current video dimensions; media packets have it clear.
                if header[0] & 0x80 != 0 {
                    let width = Int(header.uint32BigEndian(at: 4))
                    let height = Int(header.uint32BigEndian(at: 8))
                    MirrorLogger.log("Video session packet: \(width)x\(height)")
                    onVideoSize?(CGSize(width: width, height: height))
                    onStatus?("Streaming \(width) x \(height)")
                    continue
                }

                let flagsAndPTS = header.uint64BigEndian(at: 0)
                let isConfiguration = flagsAndPTS & (UInt64(1) << 62) != 0
                let presentationTimeUs = Int64(flagsAndPTS & ((UInt64(1) << 61) - 1))
                let packetSize = Int(header.uint32BigEndian(at: 8))
                let packet = try readExactly(packetSize, from: socketDescriptor)
                if isConfiguration {
                    MirrorLogger.log("H.264 configuration packet: \(packetSize) bytes")
                    try decoder.configure(with: packet)
                } else {
                    recordVideoPacket(presentationTimeUs: presentationTimeUs)
                    try decoder.decode(packet: packet, presentationTimeUs: presentationTimeUs)
                }
            }
        } catch {
            guard !isStopped else { return }
            MirrorLogger.log("Embedded session failed: \(error.localizedDescription)")
            onStatus?(error.localizedDescription)
        }
    }

    private func recordVideoPacket(presentationTimeUs: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        videoPacketCount += 1
        firstVideoPTSUs = firstVideoPTSUs ?? presentationTimeUs
        lastVideoPTSUs = presentationTimeUs
        guard now - lastVideoRateSummaryUptime >= 1,
              let firstVideoPTSUs,
              let lastVideoPTSUs else { return }

        let ptsSeconds = Double(max(lastVideoPTSUs - firstVideoPTSUs, 1)) / 1_000_000
        let ptsFPS = ptsSeconds > 0
            ? Double(max(videoPacketCount - 1, 1)) / ptsSeconds
            : 0
        MirrorLogger.log(
            String(format: "Video socket rate: packets=%d ptsFPS=%.1f", videoPacketCount, ptsFPS)
        )
        videoPacketCount = 0
        self.firstVideoPTSUs = presentationTimeUs
        self.lastVideoPTSUs = presentationTimeUs
        lastVideoRateSummaryUptime = now
    }

    private var serverPath: URL {
        let paths = [
            "/opt/homebrew/opt/scrcpy/share/scrcpy/scrcpy-server",
            "/usr/local/opt/scrcpy/share/scrcpy/scrcpy-server"
        ].map(URL.init(fileURLWithPath:))
        if let path = paths.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return path
        }
        return paths[0]
    }

    private func openSocket(port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ADBError.commandFailed("Could not create the embedded video socket.")
        }
        configureLowLatencySocket(descriptor)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connectStatus = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectStatus == 0 else {
            close(descriptor)
            throw ADBError.commandFailed("Could not connect to the embedded scrcpy video stream.")
        }
        return descriptor
    }

    private func configureLowLatencySocket(_ descriptor: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    private func startAudioStream(port: Int) {
        audioQueue.async { [weak self] in
            self?.runAudioStream(port: port)
        }
    }

    private func runAudioStream(port: Int) {
        do {
            let descriptor = try connectToAudioSocket(port: port)
            audioSocketDescriptor = descriptor
            defer {
                if audioSocketDescriptor == descriptor {
                    close(descriptor)
                    audioSocketDescriptor = nil
                }
                audioPlayer.stop()
            }

            let codec = try readExactly(4, from: descriptor)
            // scrcpy's AudioCodec.RAW ID is a big-endian ASCII `\0raw`.
            guard codec == Data([0x00, 0x72, 0x61, 0x77]) else {
                if codec == Data([0, 0, 0, 0]) {
                    onAudioStatus?("Phone audio capture is unavailable; continuing with video only")
                    return
                }
                throw ADBError.commandFailed("Embedded audio stream is not RAW PCM (codec \(codec.map { String(format: "%02x", $0) }.joined())).")
            }

            try audioPlayer.start()
            onAudioStatus?("Android audio playing on this Mac")
            MirrorLogger.log("Connected RAW PCM audio stream (48kHz stereo)")

            while !isStopped {
                let header = try readExactly(12, from: descriptor)
                let flagsAndPTS = header.uint64BigEndian(at: 0)
                let isConfiguration = flagsAndPTS & (UInt64(1) << 62) != 0
                let packetSize = Int(header.uint32BigEndian(at: 8))
                let packet = try readExactly(packetSize, from: descriptor)
                if !isConfiguration {
                    audioPlayer.enqueue(packet)
                }
            }
        } catch {
            guard !isStopped else { return }
            MirrorLogger.log("Embedded audio unavailable: \(error.localizedDescription)")
            onAudioStatus?("Phone audio unavailable: \(error.localizedDescription)")
        }
    }

    /// The decoder may briefly produce frames faster than SwiftUI can commit
    /// them. Queue at most one main-thread delivery and overwrite its payload
    /// with the newest image instead of displaying stale frames later.
    private func enqueueLatestFrame(_ image: CGImage) {
        frameLock.lock()
        decodedFrameCount += 1
        if pendingFrame != nil {
            coalescedFrameCount += 1
        }
        pendingFrame = image
        guard !isFrameDeliveryScheduled else {
            frameLock.unlock()
            return
        }
        isFrameDeliveryScheduled = true
        frameLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.deliverLatestFrame()
        }
    }

    private func deliverLatestFrame() {
        frameLock.lock()
        guard let image = pendingFrame else {
            isFrameDeliveryScheduled = false
            frameLock.unlock()
            return
        }
        pendingFrame = nil
        isFrameDeliveryScheduled = false
        deliveredFrameCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReport = now - lastFrameSummaryUptime >= 1
        let summary = shouldReport
            ? (decodedFrameCount, deliveredFrameCount, coalescedFrameCount)
            : nil
        if shouldReport {
            decodedFrameCount = 0
            deliveredFrameCount = 0
            coalescedFrameCount = 0
            lastFrameSummaryUptime = now
        }
        frameLock.unlock()

        if let summary {
            MirrorLogger.log(
                "Frame delivery: decoded=\(summary.0), displayed=\(summary.1), coalesced=\(summary.2)"
            )
        }
        onFrame?(image)
    }

    private static func touchMessage(
        action: TouchAction,
        x: UInt32,
        y: UInt32,
        width: UInt16,
        height: UInt16
    ) -> Data {
        var message = Data(capacity: 32)
        message.append(2) // INJECT_TOUCH_EVENT
        message.append(action.rawValue)
        appendBigEndian(UInt64.max - 1, to: &message) // GENERIC_FINGER
        appendBigEndian(x, to: &message)
        appendBigEndian(y, to: &message)
        appendBigEndian(width, to: &message)
        appendBigEndian(height, to: &message)
        appendBigEndian(action == .up ? UInt16(0) : UInt16.max, to: &message)
        appendBigEndian(UInt32(0), to: &message) // action button
        appendBigEndian(UInt32(0), to: &message) // buttons
        return message
    }

    private static func appendBigEndian<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func sendAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let sent = Darwin.send(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func connectToVideoSocket(port: Int) throws -> Int32 {
        var lastError: Error = ADBError.commandFailed("The embedded scrcpy server did not accept a video connection.")

        // ADB can accept a forwarded TCP connection before Android has bound
        // the corresponding abstract socket. scrcpy retries this exact race.
        for attempt in 1...100 where !isStopped {
            do {
                let descriptor = try openSocket(port: port)
                do {
                    _ = try readExactly(1, from: descriptor)
                    MirrorLogger.log("Forward tunnel accepted on attempt \(attempt)")
                    return descriptor
                } catch {
                    close(descriptor)
                    lastError = error
                    MirrorLogger.log("Forward tunnel not ready on attempt \(attempt): \(error.localizedDescription)")
                }
            } catch {
                lastError = error
                MirrorLogger.log("Forward connection failed on attempt \(attempt): \(error.localizedDescription)")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw lastError
    }

    private func connectToAudioSocket(port: Int) throws -> Int32 {
        var lastError: Error = ADBError.commandFailed("The embedded scrcpy server did not accept an audio connection.")

        for attempt in 1...100 where !isStopped {
            do {
                let descriptor = try openSocket(port: port)
                // ADB forward can accept before the abstract audio socket is
                // bound. Assign the descriptor before probing so stop() can
                // always interrupt a blocked metadata read.
                audioSocketDescriptor = descriptor
                MirrorLogger.log("Connected audio socket on attempt \(attempt)")
                return descriptor
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw lastError
    }

    private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, count))
        while data.count < count {
            let byteCount = recv(descriptor, &buffer, min(buffer.count, count - data.count), 0)
            if byteCount > 0 {
                data.append(buffer, count: Int(byteCount))
            } else if byteCount == 0 {
                MirrorLogger.log("Socket EOF while waiting for \(count) bytes; received \(data.count)")
                throw ADBError.commandFailed("The embedded scrcpy video stream closed unexpectedly.")
            } else if errno != EINTR {
                MirrorLogger.log("Socket read errno \(errno)")
                throw ADBError.commandFailed("Could not read the embedded scrcpy stream (errno \(errno)).")
            }
        }
        return data
    }
}

private extension Data {
    func uint32BigEndian(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func uint64BigEndian(at offset: Int) -> UInt64 {
        self[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

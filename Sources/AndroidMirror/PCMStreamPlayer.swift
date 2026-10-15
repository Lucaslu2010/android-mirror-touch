import AVFoundation
import Foundation

/// Plays scrcpy's `audio_codec=raw` stream: 48 kHz, stereo, signed 16-bit
/// little-endian PCM.
///
/// `AVAudioPlayerNode.scheduleBuffer` intentionally allows its internal queue
/// to grow. That is useful for music, but wrong for a live device mirror: a
/// brief scheduling stall can turn into hundreds of milliseconds of stale
/// audio. A source node instead pulls from this deliberately tiny ring buffer;
/// if the host falls behind, old samples are discarded and playback catches up.
final class PCMStreamPlayer {
    static let sampleRate = 48_000.0
    static let channels: AVAudioChannelCount = 2
    private static let bytesPerFrame = 4
    private static let maximumBufferedFrames = Int(sampleRate * 0.085)

    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private lazy var source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
        self?.render(frameCount: frameCount, into: audioBufferList)
        return noErr
    }

    // The render callback and audio socket reader run on different real-time
    // threads. The critical sections are only a few array accesses and never
    // perform allocation, I/O, or logging.
    private let ringLock = NSLock()
    private var ring: [Int16]
    private var readIndex = 0
    private var writeIndex = 0
    private var bufferedSamples = 0
    private var isPlaying = false
    private var droppedFrames = 0
    private var underrunFrames = 0
    private var lastMetricsLogTime = 0.0

    init(volume: Double) {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: Self.channels
        ) else {
            fatalError("Could not create a PCM format for scrcpy audio")
        }
        self.format = format
        self.ring = [Int16](
            repeating: 0,
            count: Self.maximumBufferedFrames * Int(Self.channels)
        )
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Float(min(max(volume, 0), 1))
    }

    func start() throws {
        ringLock.lock()
        clearLocked()
        isPlaying = true
        ringLock.unlock()

        engine.prepare()
        if !engine.isRunning {
            try engine.start()
        }
    }

    func setVolume(_ volume: Double) {
        engine.mainMixerNode.outputVolume = Float(min(max(volume, 0), 1))
    }

    func enqueue(_ packet: Data) {
        guard !packet.isEmpty, packet.count.isMultiple(of: Self.bytesPerFrame) else { return }

        ringLock.lock()
        guard isPlaying else {
            ringLock.unlock()
            return
        }

        let incomingSamples = packet.count / MemoryLayout<Int16>.size
        let capacity = ring.count
        var sourceOffset = 0
        var samplesToAppend = incomingSamples

        // A malformed or unusually large packet must not monopolize the
        // latency budget. Retain only its most recent complete frames.
        if samplesToAppend >= capacity {
            sourceOffset = samplesToAppend - capacity
            samplesToAppend = capacity
            droppedFrames += bufferedSamples / Int(Self.channels)
            bufferedSamples = 0
            readIndex = 0
            writeIndex = 0
        }

        let overflow = max(0, bufferedSamples + samplesToAppend - capacity)
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacity
            bufferedSamples -= overflow
            droppedFrames += overflow / Int(Self.channels)
        }

        packet.withUnsafeBytes { bytes in
            for sampleOffset in 0..<samplesToAppend {
                let byteOffset = (sourceOffset + sampleOffset) * MemoryLayout<Int16>.size
                let bits = UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
                ring[writeIndex] = Int16(bitPattern: bits)
                writeIndex = (writeIndex + 1) % capacity
            }
        }
        bufferedSamples += samplesToAppend

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMetricsLogTime >= 1 {
            lastMetricsLogTime = now
            let queuedMilliseconds = Double(bufferedSamples / Int(Self.channels)) / Self.sampleRate * 1_000
            let dropped = droppedFrames
            let underruns = underrunFrames
            droppedFrames = 0
            underrunFrames = 0
            MirrorLogger.log(
                String(
                    format: "Audio live buffer %.1fms (dropped=%d frames, underrun=%d frames)",
                    queuedMilliseconds,
                    dropped,
                    underruns
                )
            )
        }
        ringLock.unlock()
    }

    func stop() {
        ringLock.lock()
        isPlaying = false
        clearLocked()
        ringLock.unlock()
        engine.stop()
    }

    private func render(frameCount: AVAudioFrameCount, into audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let requestedFrames = Int(frameCount)

        // The engine asks for non-interleaved Float32 samples in this source
        // format. Clear every requested frame first, then fill what is live.
        for buffer in audioBuffers {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }

        ringLock.lock()
        guard isPlaying else {
            ringLock.unlock()
            return
        }

        let availableFrames = bufferedSamples / Int(Self.channels)
        let framesToRender = min(requestedFrames, availableFrames)
        let channelCount = min(Int(Self.channels), audioBuffers.count)

        if framesToRender < requestedFrames {
            underrunFrames += requestedFrames - framesToRender
        }

        guard framesToRender > 0, channelCount == Int(Self.channels) else {
            ringLock.unlock()
            return
        }

        for frame in 0..<framesToRender {
            let left = ring[readIndex]
            let right = ring[(readIndex + 1) % ring.count]
            if let leftData = audioBuffers[0].mData {
                leftData.assumingMemoryBound(to: Float.self)[frame] = Float(left) / 32_768
            }
            if let rightData = audioBuffers[1].mData {
                rightData.assumingMemoryBound(to: Float.self)[frame] = Float(right) / 32_768
            }
            readIndex = (readIndex + Int(Self.channels)) % ring.count
        }
        bufferedSamples -= framesToRender * Int(Self.channels)
        ringLock.unlock()
    }

    private func clearLocked() {
        readIndex = 0
        writeIndex = 0
        bufferedSamples = 0
        droppedFrames = 0
        underrunFrames = 0
        lastMetricsLogTime = 0
    }
}

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class H264VideoDecoder {
    var onFrame: ((CGImage) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var decodeSampleCount = 0
    private var decodeTotalMilliseconds = 0.0
    private var decodeMaximumMilliseconds = 0.0
    private var lastDecodeSummaryUptime = ProcessInfo.processInfo.systemUptime

    deinit {
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
        }
    }

    func configure(with configurationPacket: Data) throws {
        let parameterSets = H264VideoDecoder.annexBNALUnits(in: configurationPacket)
        guard let sps = parameterSets.first(where: { ($0.first ?? 0) & 0x1f == 7 }),
              let pps = parameterSets.first(where: { ($0.first ?? 0) & 0x1f == 8 }) else {
            throw ADBError.commandFailed("scrcpy did not provide H.264 SPS/PPS configuration data.")
        }
        MirrorLogger.log("Decoder configuration: SPS \(sps.count) bytes, PPS \(pps.count) bytes")

        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                var pointers = [
                    spsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            throw ADBError.commandFailed("Could not create an H.264 format description (\(status)).")
        }

        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        formatDescription = description

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: h264DecompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
            ] as CFDictionary,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard sessionStatus == noErr, let session else {
            throw ADBError.commandFailed("Could not create the macOS H.264 decoder (\(sessionStatus)).")
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decompressionSession = session
        MirrorLogger.log("VideoToolbox H.264 decoder created")
    }

    func decode(packet: Data, presentationTimeUs: Int64) throws {
        guard let decompressionSession, let formatDescription else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let avccData = H264VideoDecoder.avccPacket(from: packet)
        guard !avccData.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw ADBError.commandFailed("Could not allocate a video sample buffer (\(blockStatus)).")
        }
        let writeStatus = avccData.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }
        guard writeStatus == kCMBlockBufferNoErr else {
            throw ADBError.commandFailed("Could not write a video sample buffer (\(writeStatus)).")
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: presentationTimeUs, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [avccData.count],
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw ADBError.commandFailed("Could not create a H.264 sample (\(sampleStatus)).")
        }
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            // With no asynchronous/temporal flags, VideoToolbox invokes the
            // callback before returning. This preserves packet order without
            // an additional WaitForAsynchronousFrames round trip.
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        guard decodeStatus == noErr else {
            throw ADBError.commandFailed("H.264 decode failed (\(decodeStatus)).")
        }
        recordDecode(startedAt: started)
    }

    fileprivate func emit(_ pixelBuffer: CVPixelBuffer) {
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image) == noErr,
              let image else { return }
        onFrame?(image)
    }

    private func recordDecode(startedAt: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        let milliseconds = (now - startedAt) * 1_000
        decodeSampleCount += 1
        decodeTotalMilliseconds += milliseconds
        decodeMaximumMilliseconds = max(decodeMaximumMilliseconds, milliseconds)
        guard now - lastDecodeSummaryUptime >= 1 else { return }

        let average = decodeTotalMilliseconds / Double(max(decodeSampleCount, 1))
        MirrorLogger.log(
            "Decoder latency: frames=\(decodeSampleCount), avg=\(String(format: "%.2f", average))ms, max=\(String(format: "%.2f", decodeMaximumMilliseconds))ms"
        )
        decodeSampleCount = 0
        decodeTotalMilliseconds = 0
        decodeMaximumMilliseconds = 0
        lastDecodeSummaryUptime = now
    }

    private static func annexBNALUnits(in data: Data) -> [Data] {
        let bytes = Array(data)
        var startCodes: [(start: Int, length: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                startCodes.append((index, 3))
                index += 3
            } else if index + 4 < bytes.count,
                      bytes[index] == 0, bytes[index + 1] == 0,
                      bytes[index + 2] == 0, bytes[index + 3] == 1 {
                startCodes.append((index, 4))
                index += 4
            } else {
                index += 1
            }
        }
        guard !startCodes.isEmpty else { return data.isEmpty ? [] : [data] }

        return startCodes.enumerated().compactMap { offset, code in
            let payloadStart = code.start + code.length
            let payloadEnd = offset + 1 < startCodes.count ? startCodes[offset + 1].start : bytes.count
            guard payloadStart < payloadEnd else { return nil }
            return Data(bytes[payloadStart..<payloadEnd])
        }
    }

    private static func avccPacket(from annexBPacket: Data) -> Data {
        let nalUnits = annexBNALUnits(in: annexBPacket)
        var result = Data()
        for nalUnit in nalUnits {
            var length = UInt32(nalUnit.count).bigEndian
            result.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
            result.append(nalUnit)
        }
        return result
    }
}

private let h264DecompressionCallback: VTDecompressionOutputCallback = {
    refCon, _, status, _, imageBuffer, _, _ in
    guard status == noErr, let refCon, let imageBuffer else { return }
    let decoder = Unmanaged<H264VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.emit(imageBuffer)
}

import AUNCoreBridge
import AVFoundation
import VideoToolbox

public struct EncodeOutcome: Hashable, Sendable {
    public var usedHardware: Bool
    public var output: URL
}

public enum EncodeError: Error, Sendable {
    case noVideoTrack, sessionFailed(OSStatus), writerFailed, readerFailed
}

/// Thread-safe list of frames delivered by VideoToolbox's callback queue.
private final class EncodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CMSampleBuffer] = []
    private var failure: OSStatus?

    func append(_ frame: CMSampleBuffer) { lock.withLock { frames.append(frame) } }
    func fail(_ status: OSStatus) { lock.withLock { failure = status } }
    func drain() -> [CMSampleBuffer] {
        lock.withLock {
            defer { frames.removeAll() }
            return frames
        }
    }
    var error: OSStatus? { lock.withLock { failure } }
}

/// Reads a source, compresses it with VideoToolbox (hardware when the Mac has it) and writes MP4.
/// Audio is copied without re-encoding in this prototype.
public struct VideoToolboxEncoder: Sendable {
    public init() {}

    private func outputSize(for track: AVAssetTrack, maxHeight: Int) async throws -> CGSize {
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = natural.applying(transform)
        let (width, height) = (abs(size.width), abs(size.height))
        let scale = min(1, CGFloat(maxHeight) / height)
        func even(_ value: CGFloat) -> CGFloat { (value * scale / 2).rounded() * 2 }
        return CGSize(width: even(width), height: even(height))
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func encode(_ plan: EncodePlan, progress: @Sendable (Double) async -> Void) async throws -> EncodeOutcome {
        let asset = AVURLAsset(url: plan.source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw EncodeError.noVideoTrack }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let audioHint = try await audioTrack?.load(.formatDescriptions).first
        let total = try await asset.load(.duration).seconds
        let size = try await outputSize(for: videoTrack, maxHeight: plan.preset.maxHeight)

        try? FileManager.default.removeItem(at: plan.destination)
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.add(output)
            audioOutput = output
        }

        let session = try makeSession(size: size, preset: plan.preset)
        defer { VTCompressionSessionInvalidate(session) }
        let frames = EncodedFrames()
        guard reader.startReading() else { throw EncodeError.readerFailed }

        let writer = try AVAssetWriter(outputURL: plan.destination, fileType: .mp4)
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        // The writer can only start once the first compressed frame provides the format description.
        func prepareWriter(first: CMSampleBuffer) throws {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: first.formatDescription)
            writer.add(input)
            videoInput = input
            if audioOutput != nil, let audioHint {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioHint)
                writer.add(audio)
                audioInput = audio
            }
            guard writer.startWriting() else { throw EncodeError.writerFailed }
            writer.startSession(atSourceTime: first.presentationTimeStamp)
        }

        func flush() async throws {
            for frame in frames.drain() {
                if videoInput == nil { try prepareWriter(first: frame) }
                guard let input = videoInput else { throw EncodeError.writerFailed }
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                    try copyAvailableAudio(audioOutput, into: audioInput)
                }
                guard input.append(frame) else { throw EncodeError.writerFailed }
            }
        }

        while let sample = videoOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let image = sample.imageBuffer else { continue }
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: image, presentationTimeStamp: sample.presentationTimeStamp,
                duration: sample.duration, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, buffer in
                if status != noErr {
                    frames.fail(status)
                } else if let buffer {
                    frames.append(buffer)
                }
            }
            guard status == noErr else { throw EncodeError.sessionFailed(status) }
            if let failure = frames.error { throw EncodeError.sessionFailed(failure) }
            try await flush()
            if total > 0 { await progress(min(1, sample.presentationTimeStamp.seconds / total)) }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        try await flush()
        guard reader.status != .failed else { throw EncodeError.readerFailed }

        try await finishAudio(audioOutput, into: audioInput)
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw EncodeError.writerFailed }
        await progress(1)
        return EncodeOutcome(usedHardware: usesHardware(session), output: plan.destination)
    }

    /// Moves audio while the input has room, so slow video writing never stalls interleaving.
    private func copyAvailableAudio(_ output: AVAssetReaderTrackOutput?, into input: AVAssetWriterInput?) throws {
        guard let output, let input else { return }
        while input.isReadyForMoreMediaData, let sample = output.copyNextSampleBuffer() {
            guard input.append(sample) else { throw EncodeError.writerFailed }
        }
    }

    private func finishAudio(_ output: AVAssetReaderTrackOutput?, into input: AVAssetWriterInput?) async throws {
        guard let output, let input else { return }
        while let sample = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard input.append(sample) else { throw EncodeError.writerFailed }
        }
    }

    private func makeSession(size: CGSize, preset: EncodePreset) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        var specification: [CFString: Any] = [:]
        if #available(iOS 17.4, *) { specification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true }
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(size.width), height: Int32(size.height),
            codecType: preset.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw EncodeError.sessionFailed(status) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        // Reordering stays off, so frames arrive in presentation order and can be appended directly.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: preset.averageBitRate as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    private func usesHardware(_ session: VTCompressionSession) -> Bool {
        guard #available(iOS 17.4, *) else { return true }
        var value: CFBoolean?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(
                session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: $0)
        }
        return status == noErr && value == kCFBooleanTrue
    }
}

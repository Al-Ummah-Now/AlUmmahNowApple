import AUNCoreBridge
import AVFoundation
import VideoToolbox

/// What the ladder and the encoder need to know about a source video.
public struct SourceVideoInfo: Hashable, Sendable {
    /// Coded size, before rotation (what Core's `hls_ladder` takes).
    public var codedWidth: Int
    public var codedHeight: Int
    /// Clockwise degrees: 0, 90, 180 or 270.
    public var rotation: Int
    public var fps: Double
    public var hasAudio: Bool
    public var durationSeconds: Double

    public init(codedWidth: Int, codedHeight: Int, rotation: Int, fps: Double, hasAudio: Bool, durationSeconds: Double) {
        self.codedWidth = codedWidth
        self.codedHeight = codedHeight
        self.rotation = rotation
        self.fps = fps
        self.hasAudio = hasAudio
        self.durationSeconds = durationSeconds
    }

    /// Reads the first video track's size, rotation and frame rate.
    public static func inspect(_ url: URL) async throws -> SourceVideoInfo {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw EncodeError.noVideoTrack }
        let (size, transform, fps) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let duration = try await asset.load(.duration).seconds
        return SourceVideoInfo(
            codedWidth: Int(size.width.rounded()), codedHeight: Int(size.height.rounded()),
            rotation: rotation(of: transform), fps: Double(fps), hasAudio: hasAudio,
            durationSeconds: duration.isFinite ? duration : 0)
    }

    static func rotation(of transform: CGAffineTransform) -> Int {
        let degrees = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        return ((degrees % 360) + 360) % 360 / 90 * 90
    }
}

/// Encodes one rung of the server's ladder to a progressive MP4 the server accepts as a pre-encoded rendition (D11):
/// H.264 4:2:0 8-bit at the rung's profile, a keyframe exactly every `gopSeconds` (forced on the 2 s grid, never
/// on scene cuts), peak bitrate under the rung's `maxrate`, a constant frame rate capped at `maxFPS` for sources above
/// 31 fps, and AAC stereo 48 kHz at the rung's audio bitrate when the source has sound.
public struct RungEncoder: Sendable {
    public init() {}

    /// Frames per second the rung is encoded at.
    static func outputFPS(rung: HLSRung, source: Double) -> Double {
        rung.outputFPS(source: source > 0 ? source : rung.maxFPS)
    }

    /// The display transform followed by the scale that fills the rung's frame.
    static func renderTransform(natural: CGSize, preferred: CGAffineTransform, render: CGSize) -> CGAffineTransform {
        let display = natural.applying(preferred)
        let (width, height) = (abs(display.width), abs(display.height))
        guard width > 0, height > 0 else { return preferred }
        return preferred.concatenating(CGAffineTransform(scaleX: render.width / width, y: render.height / height))
    }

    /// Frame indexes, in a constant-rate stream, that start a GOP: the first frame at or after each `gop` boundary.
    static func isKeyframe(frame: Int, fps: Double, gop: Double) -> Bool {
        guard frame > 0 else { return true }
        let time = Double(frame) / fps
        let previous = Double(frame - 1) / fps
        return floor((time + 1e-9) / gop) > floor((previous + 1e-9) / gop)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    public func encode(
        source: URL, rung: HLSRung, to output: URL, progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw EncodeError.noVideoTrack }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (natural, preferred, sourceFPS) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let total = duration.seconds
        let fps = Self.outputFPS(rung: rung, source: Double(sourceFPS))
        let render = CGSize(width: rung.width / 2 * 2, height: rung.height / 2 * 2)

        // The video composition rotates, scales and resamples to a constant frame rate in one pass.
        let composition = AVMutableVideoComposition()
        composition.renderSize = render
        composition.frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(Self.renderTransform(natural: natural, preferred: preferred, render: render), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: Self.pcmSettings)
            reader.add(output)
            audioOutput = output
        }

        let session = try makeSession(size: render, rung: rung, fps: fps)
        defer { VTCompressionSessionInvalidate(session) }
        let frames = CompressedFrames()
        guard reader.startReading() else { throw EncodeError.readerFailed }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        var videoInput: AVAssetWriterInput?
        var audio: AudioPump?
        // The writer starts once the first compressed frame gives the format description.
        func prepareWriter(first: CMSampleBuffer) throws {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: first.formatDescription)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            videoInput = input
            if let audioOutput {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(rung))
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                audio = AudioPump(output: audioOutput, input: input)
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
                    try audio?.pumpAvailable()
                }
                guard input.append(frame) else { throw EncodeError.writerFailed }
            }
        }

        let forceKeyframe = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        var index = 0
        while let sample = videoOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let image = sample.imageBuffer else { continue }
            let key = Self.isKeyframe(frame: index, fps: fps, gop: rung.gopSeconds)
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: image, presentationTimeStamp: sample.presentationTimeStamp,
                duration: composition.frameDuration, frameProperties: key ? forceKeyframe : nil, infoFlagsOut: nil
            ) { status, _, buffer in
                if status != noErr {
                    frames.fail(status)
                } else if let buffer {
                    frames.append(buffer)
                }
            }
            guard status == noErr else { throw EncodeError.sessionFailed(status) }
            if let failure = frames.error { throw EncodeError.sessionFailed(failure) }
            index += 1
            try await flush()
            try audio?.pumpAvailable()
            if total > 0 { await progress(min(0.99, sample.presentationTimeStamp.seconds / total)) }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        try await flush()
        guard reader.status != .failed, videoInput != nil else { throw EncodeError.readerFailed }

        // Video is done: mark it so the writer stops holding audio back to interleave with it.
        videoInput?.markAsFinished()
        try await audio?.drain()
        await writer.finishWriting()
        guard writer.status == .completed else { throw EncodeError.writerFailed }
        await progress(1)
    }

    private static var stereoLayout: Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    /// Decoded audio resampled to 48 kHz and mixed to stereo.
    static var pcmSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: stereoLayout, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
    }

    static func aacSettings(_ rung: HLSRung) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: stereoLayout, AVEncoderBitRateKey: rung.audioBitrate,
        ]
    }

    private func makeSession(size: CGSize, rung: HLSRung, fps: Double) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        var specification: [CFString: Any] = [:]
        if #available(iOS 17.4, *) { specification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true }
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw EncodeError.sessionFailed(status) }
        let profile =
            rung.profile == "main" ? kVTProfileLevel_H264_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        let keyframeFrames = max(1, Int((fps * rung.gopSeconds).rounded()))
        // Peak: never more than 90 % of maxrate in any one second; average under that.
        let peakBytesPerSecond = Double(rung.maxrate) * 0.9 / 8
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanFalse as Any,
            // In presentation order, so frames can be appended as they come.
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse as Any,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_H264EntropyMode: kVTH264EntropyMode_CABAC,
            kVTCompressionPropertyKey_AverageBitRate: rung.averageBitRate,
            kVTCompressionPropertyKey_DataRateLimits: [peakBytesPerSecond, 1.0] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: keyframeFrames,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: rung.gopSeconds,
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if result != noErr { AUNLog.studio.info("Encoder property \(key as String) not set: \(result)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }
}

/// Moves decoded audio into the AAC input. The writer interleaves, so video waits on audio and audio on video: audio
/// is pumped whenever video waits, and the input is marked finished the moment the source has no more, or the
/// writer would hold video back waiting for audio that never comes.
private final class AudioPump {
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    private(set) var finished = false

    init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
        self.output = output
        self.input = input
    }

    func pumpAvailable() throws {
        while !finished, input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                finished = true
                return
            }
            guard input.append(sample) else { throw EncodeError.writerFailed }
        }
    }

    func drain() async throws {
        while !finished {
            try Task.checkCancellation()
            try pumpAvailable()
            if !finished { try await Task.sleep(for: .milliseconds(2)) }
        }
    }
}

/// Frames delivered on VideoToolbox's callback queue.
private final class CompressedFrames: @unchecked Sendable {
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

import AUNCoreBridge
import AVFoundation
import Foundation
import Testing

@testable import AUNStudio

// Pre-encoded renditions (E19 19.3, D11): the rung encoder's output, the pipeline, and how the upload queue runs it.

/// One ordered log shared by the fakes, so tests can check what happened before what.
private actor CallLog {
    var calls: [String] = []
    func add(_ call: String) { calls.append(call) }
}

private struct FakePackaging: RenditionPackaging {
    var rungs: [HLSRung] = [
        HLSRung(
            name: "360p", width: 640, height: 360, maxrate: 1_000_000, bufsize: 2_000_000, audioBitrate: 96_000,
            profile: "main"),
        HLSRung(
            name: "720p", width: 1280, height: 720, maxrate: 3_000_000, bufsize: 6_000_000, audioBitrate: 128_000,
            profile: "high"),
    ]

    func ladder(width: Int, height: Int, rotation: Int) -> [HLSRung] { rungs }

    func package(mp4: URL, outputDirectory: URL, segmentSeconds: Double) async throws -> HLSPackage {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var files: [StagedFile] = []
        for name in ["index.m3u8", "init.mp4", "seg_00001.m4s"] {
            try Data(repeating: 1, count: 4).write(to: outputDirectory.appending(path: name))
            files.append(StagedFile(path: name, bytes: 4))
        }
        return HLSPackage(files: files, durationMs: 1000)
    }

    func files(root: URL, rungs: [String]) throws -> [StagedFile] {
        try rungs.flatMap { rung in
            try FileManager.default.contentsOfDirectory(atPath: root.appending(path: rung).path).sorted().map {
                StagedFile(path: "\(rung)/\($0)", bytes: 4)
            }
        }
    }
}

private actor LoggingRenditions: RenditionsServicing {
    let log: CallLog
    init(log: CallLog) { self.log = log }

    func createRenditions(
        videoID: String, rungs: [String], files: [StagedFile], encoder: String, channelID: String?
    ) async throws -> RenditionStaging {
        await log.add("renditions:create:\(rungs.joined(separator: ",")):\(files.count)")
        return RenditionStaging(stagingID: "s1", maxFileBytes: nil)
    }
    func putRenditionFile(
        videoID: String, stagingID: String, file: StagedFile, bytes: Data, channelID: String?
    ) async throws { await log.add("renditions:put:\(file.path)") }
    func completeRenditions(videoID: String, stagingID: String, channelID: String?) async throws {
        await log.add("renditions:complete")
    }
    func cancelRenditions(videoID: String, stagingID: String, channelID: String?) async throws {
        await log.add("renditions:cancel")
    }
}

private actor MinimalStudio: StudioServicing {
    let log: CallLog
    init(log: CallLog) { self.log = log }

    func channels() async throws -> [StudioChannel] { FixtureStudioService.channels }
    func playlists(channelID: String) async throws -> [StudioPlaylist] { [] }
    func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
        UploadTicket(videoID: "v1", tusSessionID: "s", chunkSize: 1 << 20)
    }
    func resumeUpload(videoID: String, channelID: String) async throws -> UploadTicket {
        UploadTicket(videoID: videoID, tusSessionID: "s2", chunkSize: 1 << 20)
    }
    func completeUpload(videoID: String, fileSize: Int64, channelID: String) async throws {
        await log.add("upload:complete")
    }
    func tusEndpoint() async throws -> (url: URL, headers: [String: String]) {
        (URL(string: "https://fixtures.invalid/api/videos/tus")!, [:])
    }
    func setLanguage(_ language: VideoLanguage, videoID: String, channelID: String) async throws {}
    func addToPlaylists(_ playlistIDs: [String], videoID: String, orderKey: String, channelID: String) async throws {}
    func schedule(videoID: String, at date: Date, timeZone: TimeZone, channelID: String) async throws {}
}

private let info = SourceVideoInfo(
    codedWidth: 1920, codedHeight: 1080, rotation: 0, fps: 30, hasAudio: true, durationSeconds: 10)

private func preEncoder(
    log: CallLog, packaging: FakePackaging = FakePackaging(), encode: PreEncoder.Encode? = nil
) -> PreEncoder {
    var encoder = PreEncoder(
        packaging: packaging, renditions: LoggingRenditions(log: log),
        workRoot: FileManager.default.temporaryDirectory.appending(path: "pre-\(UUID().uuidString)"))
    encoder.inspect = { _ in info }
    encoder.encode =
        encode ?? { _, rung, output, progress in
            await log.add("encode:\(rung.name)")
            await progress(0.5)
            try Data(repeating: 0, count: 8).write(to: output)
        }
    encoder.uploaderPause = { _ in }
    return encoder
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PreEncoder.Status] = []
    func append(_ value: PreEncoder.Status) { lock.withLock { stored.append(value) } }
    var values: [PreEncoder.Status] { lock.withLock { stored } }
}

struct PreEncoderTests {
    @Test func encodesEveryRungThenSendsTheFiles() async {
        let log = CallLog()
        let statuses = StatusLog()
        let outcome = await preEncoder(log: log).run(
            source: URL(fileURLWithPath: "/source.mov"), videoID: "v1", channelID: "c1", encoder: "Studio"
        ) { statuses.append($0) }
        #expect(outcome == .ready)
        let calls = await log.calls
        #expect(calls.prefix(3) == ["encode:360p", "encode:720p", "renditions:create:360p,720p:6"])
        #expect(calls.last == "renditions:complete")
        #expect(calls.filter { $0.hasPrefix("renditions:put:") }.count == 6)
        let fractions = statuses.values.map(\.fraction)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
        #expect(statuses.values.contains { $0.phase == .encoding(rung: "720p", index: 2, count: 2) })
    }

    @Test func anEncodeFailureSendsNothing() async {
        let log = CallLog()
        let outcome = await preEncoder(log: log) { _, _, _, _ in throw EncodeError.writerFailed }.run(
            source: URL(fileURLWithPath: "/source.mov"), videoID: "v1", channelID: nil, encoder: "Studio")
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(await log.calls.isEmpty)
    }

    @Test func noLadderMeansNoPreEncode() async {
        let log = CallLog()
        let outcome = await preEncoder(log: log, packaging: FakePackaging(rungs: [])).run(
            source: URL(fileURLWithPath: "/source.mov"), videoID: "v1", channelID: nil, encoder: "Studio")
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(await log.calls.isEmpty)
    }

    @Test func cancellingStopsBeforeSending() async {
        let log = CallLog()
        let encoder = preEncoder(log: log) { _, _, _, _ in try await Task.sleep(for: .seconds(30)) }
        let task = Task {
            await encoder.run(source: URL(fileURLWithPath: "/s.mov"), videoID: "v1", channelID: nil, encoder: "S")
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(await log.calls.isEmpty)
    }
}

@MainActor
struct PreEncodeQueueTests {
    private func job(preEncode: Bool) throws -> UploadJob {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data(repeating: 7, count: 300_000).write(to: url)
        return UploadJob(
            batchID: UUID(), index: 0, file: url, ownsFile: true, fileSize: 300_000, mimeType: "video/mp4",
            title: "One", settings: UploadSettings(preEncode: preEncode), channelID: "c1", accountID: "a1")
    }

    private func queue(log: CallLog, encoder: PreEncoder?) -> UploadQueue {
        let queue = UploadQueue(
            studio: MinimalStudio(log: log), transfer: FixtureTUSTransfer(delay: .zero),
            store: UploadStore(url: FileManager.default.temporaryDirectory.appending(path: "q-\(UUID().uuidString).json")),
            preEncoder: encoder, encoderName: "Studio test")
        queue.accountID = "a1"
        return queue
    }

    private func wait(_ queue: UploadQueue, until done: (UploadJob) -> Bool) async throws {
        for _ in 0..<300 {
            if let job = queue.jobs.first, done(job) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("queue did not reach the expected state: \(String(describing: queue.jobs.first))")
    }

    @Test func renditionsCompleteBeforeTheOriginal() async throws {
        let log = CallLog()
        let queue = queue(log: log, encoder: preEncoder(log: log))
        queue.enqueue([try job(preEncode: true)])
        try await wait(queue) { $0.state == .done }
        #expect(queue.jobs[0].preEncode == .ready)
        let calls = await log.calls
        let renditions = try #require(calls.firstIndex(of: "renditions:complete"))
        let original = try #require(calls.firstIndex(of: "upload:complete"))
        #expect(renditions < original)
    }

    @Test func aFailedPreEncodeNeverFailsTheUpload() async throws {
        let log = CallLog()
        let queue = queue(log: log, encoder: preEncoder(log: log) { _, _, _, _ in throw EncodeError.writerFailed })
        queue.enqueue([try job(preEncode: true)])
        try await wait(queue) { $0.state == .done }
        #expect(queue.jobs[0].preEncode == .failed)
        #expect(await log.calls == ["upload:complete"])
    }

    @Test func skippingTheWaitCompletesTheUploadAtOnce() async throws {
        let log = CallLog()
        let queue = queue(log: log, encoder: preEncoder(log: log) { _, _, _, _ in try await Task.sleep(for: .seconds(60)) })
        queue.enqueue([try job(preEncode: true)])
        try await wait(queue) { $0.state == .finishing && $0.preEncode == .running }
        queue.skipPreEncode(queue.jobs[0].id)
        try await wait(queue) { $0.state == .done }
        #expect(queue.jobs[0].preEncode == .skipped)
        #expect(await log.calls == ["upload:complete"])
    }

    @Test func offByDefault() async throws {
        let log = CallLog()
        let queue = queue(log: log, encoder: preEncoder(log: log))
        queue.enqueue([try job(preEncode: false)])
        try await wait(queue) { $0.state == .done }
        #expect(queue.jobs[0].preEncode == nil)
        #expect(await log.calls == ["upload:complete"])
        #expect(UploadSettings().preEncode == false)
    }

    @Test func olderSavedSettingsDecodeWithPreEncodeOff() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(UploadSettings(preEncode: true))) as? [String: Any]
        json?.removeValue(forKey: "preEncode")
        let data = try JSONSerialization.data(withJSONObject: json ?? [:])
        #expect(try JSONDecoder().decode(UploadSettings.self, from: data).preEncode == false)
    }
}

struct RungEncoderTests {
    /// A 60 fps 160×90 movie with mono 44.1 kHz AAC sound, so the rung encoder has to cap the frame rate and
    /// resample and upmix the audio.
    static func makeSource(seconds: Int = 5) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "src-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audio = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw EncodeError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format)
        let samplesPerChunk = 4_410
        let (frames, chunks) = (seconds * 60, seconds * 10)
        var (frame, chunk) = (0, 0)
        var (videoDone, audioDone) = (false, false)
        // Feed whichever input is ready; each waits on the other to interleave.
        while frame < frames || chunk < chunks {
            if writer.status == .failed { throw writer.error ?? EncodeError.writerFailed }
            var progressed = false
            if frame < frames, video.isReadyForMoreMediaData {
                adaptor.append(try Self.blankFrame(), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 60))
                frame += 1
                progressed = true
            }
            if chunk < chunks, audio.isReadyForMoreMediaData {
                let sample = try Self.silence(chunk: chunk, samples: samplesPerChunk, format: format)
                guard audio.append(sample) else { throw writer.error ?? EncodeError.writerFailed }
                chunk += 1
                progressed = true
            }
            if frame == frames, !videoDone {
                video.markAsFinished()
                videoDone = true
            }
            if chunk == chunks, !audioDone {
                audio.markAsFinished()
                audioDone = true
            }
            if !progressed { try await Task.sleep(for: .milliseconds(2)) }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw EncodeError.writerFailed }
        return url
    }

    static func blankFrame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw EncodeError.writerFailed }
        return buffer
    }

    /// 0.1 s of silent 16-bit mono PCM.
    static func silence(chunk: Int, samples: Int, format: CMAudioFormatDescription?) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: samples * 2, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: samples * 2, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block, let format else { throw EncodeError.writerFailed }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: samples * 2)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples,
            presentationTimeStamp: CMTime(value: CMTimeValue(chunk * samples), timescale: 44_100), packetDescriptions: nil,
            sampleBufferOut: &sample)
        guard let sample else { throw EncodeError.writerFailed }
        return sample
    }

    @Test func encodesARungByTheServerRules() async throws {
        let source = try await Self.makeSource()
        let output = FileManager.default.temporaryDirectory.appending(path: "rung-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        let rung = HLSRung(
            name: "t", width: 128, height: 72, maxrate: 400_000, bufsize: 800_000, audioBitrate: 64_000, profile: "main")
        try await RungEncoder().encode(source: source, rung: rung, to: output)

        let asset = AVURLAsset(url: output)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, fps) = try await video.load(.naturalSize, .nominalFrameRate)
        #expect(size == CGSize(width: 128, height: 72))
        #expect(abs(Double(fps) - 30) < 0.5)
        let videoFormat = try #require(try await video.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(videoFormat) == kCMVideoCodecType_H264)

        // Keyframes exactly on the 2 s grid, and nowhere else.
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(samples)
        #expect(reader.startReading())
        var keyframes: [Double] = []
        while let sample = samples.copyNextSampleBuffer() {
            // The reader also hands out empty marker buffers; only frames count.
            guard sample.numSamples > 0, sample.presentationTimeStamp.isNumeric else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            if !notSync { keyframes.append((sample.presentationTimeStamp.seconds * 100).rounded() / 100) }
        }
        #if os(macOS)
            // Desktop Studio (where pre-encoding runs): exactly the 2 s grid.
            #expect(keyframes == [0, 2, 4])
        #else
            // The simulator's software encoder may add one; the grid keyframes must all be there.
            #expect(Set([0.0, 2.0, 4.0]).isSubset(of: Set(keyframes)))
        #endif

        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioFormat = try #require(try await audio.load(.formatDescriptions).first)
        let description = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee)
        #expect(description.mFormatID == kAudioFormatMPEG4AAC)
        #expect(description.mSampleRate == 48_000)
        #expect(description.mChannelsPerFrame == 2)

        let bytes = try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let seconds = try await asset.load(.duration).seconds
        #expect(Double(bytes * 8) / seconds < Double(rung.maxrate))
    }

    @Test func keyframeGridAndFrameRateRules() {
        let rung = HLSRung(name: "t", width: 2, height: 2, maxrate: 1, bufsize: 1, audioBitrate: 1, profile: "main")
        #expect(RungEncoder.outputFPS(rung: rung, source: 60) == 30)
        #expect(RungEncoder.outputFPS(rung: rung, source: 31) == 31)
        #expect(RungEncoder.outputFPS(rung: rung, source: 25) == 25)
        let thirty = (0..<130).filter { RungEncoder.isKeyframe(frame: $0, fps: 30, gop: 2) }
        #expect(thirty == [0, 60, 120])
        let ntsc = (0..<130).filter { RungEncoder.isKeyframe(frame: $0, fps: 30_000.0 / 1001, gop: 2) }
        #expect(ntsc == [0, 60, 120])
        #expect(SourceVideoInfo.rotation(of: .identity) == 0)
        #expect(SourceVideoInfo.rotation(of: CGAffineTransform(rotationAngle: .pi / 2)) == 90)
        #expect(SourceVideoInfo.rotation(of: CGAffineTransform(rotationAngle: -.pi / 2)) == 270)
    }
}
/// The queue never calls these.
extension MinimalStudio {
    func content(channelID: String, query: ContentQuery, cursor: String?) async throws -> ContentPage {
        ContentPage(items: [], cursor: nil)
    }
    func contentCounts(channelID: String) async throws -> ContentCounts { [:] }
    func updateVideo(_ id: String, _ edit: VideoEdit, channelID: String) async throws {}
    func deleteVideos(_ ids: [String], channelID: String) async throws -> BulkResult { BulkResult(items: []) }
    func bulkUpdate(_ ids: [String], _ changes: BulkChanges, channelID: String) async throws -> BulkResult {
        BulkResult(items: [])
    }
    func bulkSchedule(_ ids: [String], startAt: Date, intervalMinutes: Int, timeZone: TimeZone) async throws -> BulkResult {
        BulkResult(items: [])
    }
    func addToPlaylist(_ playlistID: String, videoIDs: [String], channelID: String) async throws {}
    func deletedVideos(channelID: String, cursor: String?) async throws -> (items: [DeletedVideo], cursor: String?) {
        ([], nil)
    }
    func restoreVideos(_ ids: [String]) async throws -> BulkResult { BulkResult(items: []) }
    func purgeVideos(_ ids: [String]) async throws -> BulkResult { BulkResult(items: []) }
    func channelStats(channelID: String, period: DateInterval) async throws -> ChannelStats { ChannelStats(totalViews: 0) }
    func videoStats(videoID: String, period: DateInterval) async throws -> VideoStats {
        VideoStats(videoID: videoID, title: "", views: 0)
    }
}

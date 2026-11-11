import AUNCoreBridge
import AVFoundation
import Foundation
import Testing

@testable import AUNStudio

private func clip(_ duration: Double) -> EditClip { EditClip(source: URL(fileURLWithPath: "/a.mp4"), duration: duration) }

private func makeVideo(seconds: Int) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<(seconds * 10) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
        adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return url
}

@Suite struct EditDecisionListTests {
    @Test func splitKeepsTotalAndSourceOffsets() {
        var list = EditDecisionList(clips: [clip(10)])
        list.split(at: 4)
        #expect(list.clips.map(\.duration) == [4, 6])
        #expect(list.clips[1].sourceStart == 4)
        #expect(list.duration == 10)
    }

    @Test func splitIgnoresEdges() {
        var list = EditDecisionList(clips: [clip(10)])
        list.split(at: 0.01)
        list.split(at: 9.99)
        #expect(list.clips.count == 1)
    }

    @Test func rippleDeleteClosesGap() {
        let middle = clip(2)
        var list = EditDecisionList(clips: [clip(1), middle, clip(3)])
        list.rippleDelete(id: middle.id)
        #expect(list.duration == 4)
        #expect(list.locate(1.5)?.index == 1)
    }

    @Test func moveClampsAtEnds() {
        let first = clip(1)
        var list = EditDecisionList(clips: [first, clip(2)])
        list.move(id: first.id, by: 5)
        #expect(list.clips.last?.id == first.id)
        list.move(id: first.id, by: -5)
        #expect(list.clips.first?.id == first.id)
    }

    @Test func trimStaysInsideClip() {
        let item = clip(10)
        var list = EditDecisionList(clips: [item])
        list.trim(id: item.id, start: 2, end: 8)
        #expect(list.clips[0].sourceStart == 2)
        #expect(list.clips[0].duration == 6)
        list.trim(id: item.id, start: -5, end: 100)
        #expect(list.clips[0].duration == 6)
    }
}

@MainActor @Suite struct QueueTests {
    private let good = URL(fileURLWithPath: "/good.mp4")
    private let bad = URL(fileURLWithPath: "/bad.mp4")

    @Test func encodeQueueProducesPlayableHEVCOrH264() async throws {
        let source = try await makeVideo(seconds: 1)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let queue = EncodeQueue(outputDirectory: directory)
        queue.add([source])
        queue.start(preset: EncodePreset(name: "t", codec: .h264, maxHeight: 120, averageBitRate: 200_000))
        await queue.waitUntilFinished()
        let item = try #require(queue.items.first)
        #expect(item.status == .done)
        let asset = AVURLAsset(url: try #require(item.output))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize).height == 120)
        #expect(try await asset.load(.duration).seconds > 0.5)
    }

    @Test func encodeOfNonVideoFails() async throws {
        let junk = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data("not video".utf8).write(to: junk)
        let queue = EncodeQueue(outputDirectory: FileManager.default.temporaryDirectory)
        queue.add([junk])
        queue.start()
        await queue.waitUntilFinished()
        #expect(queue.items.first?.status == .failed)
    }

    @Test func compositionFollowsEditListAndExports() async throws {
        let source = try await makeVideo(seconds: 2)
        var list = EditDecisionList(clips: [EditClip(source: source, duration: 2)])
        list.split(at: 1)
        list.rippleDelete(id: list.clips[0].id)
        let composition = try await CompositionBuilder.build(list)
        #expect(abs(composition.duration.seconds - 1) < 0.15)
        let output = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try await CompositionBuilder.export(list, to: output)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func liveIsUnavailableUntilProviderDecided() async {
        let live = UnavailableLiveBroadcaster()
        #expect(!live.isAvailable)
        let config = LiveIngestConfiguration(transport: .srt, url: URL(fileURLWithPath: "/x"), streamKey: "k")
        await #expect(throws: LiveBroadcastError.self) { try await live.start(config) }
    }
}

#if os(macOS)
    @Test func timelineGeometryMapsTimeAndClips() {
        let list = EditDecisionList(clips: [clip(2), clip(3)])
        let layout = TimelineLayout(list: list, pointsPerSecond: 10)
        #expect(layout.frames(height: 50).map(\.frame.maxX) == [20, 50])
        #expect(layout.time(atX: 35) == 3.5)
        #expect(layout.time(atX: 999) == 5)
        #expect(layout.x(atTime: 2) == 20)
    }
#endif

import AUNCoreBridge
import AVFoundation
import Testing

@testable import AUNPlayer

/// Writes a short H.264 file, so playback is tested with no network.
private func makeVideo(seconds: Int = 2) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<(seconds * 10) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    return url
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    #expect(condition())
}

@MainActor @Suite(.serialized) struct PlayerControllerTests {
    private func controller() -> PlayerController {
        PlayerController { _ in "WEBVTT\n\n00:00.000 --> 00:10.000\nمرحبا\n" }
    }

    private func track() -> SubtitleTrack {
        SubtitleTrack(id: "ar", language: "ar", label: "AR", url: URL(fileURLWithPath: "/tmp/ar.vtt"))
    }

    @Test func loadsLocalVideoAndReportsDuration() async throws {
        let sut = controller()
        sut.load(PlaybackItem(url: try await makeVideo(), title: "T"), autoplay: false)
        #expect(sut.phase == .loading)
        try await waitUntil { sut.phase == .ready && sut.duration > 1 }
        sut.stop()
        #expect(sut.phase == .idle)
    }

    @Test func missingMediaFails() async throws {
        let sut = controller()
        sut.load(PlaybackItem(url: URL(fileURLWithPath: "/nonexistent.mp4"), title: "T"), autoplay: false)
        try await waitUntil { sut.phase == .failed }
    }

    @Test func speedAndQualityApplyToPlayer() async throws {
        let sut = controller()
        sut.load(PlaybackItem(url: try await makeVideo(), title: "T", resolutions: ["240p"]), autoplay: false)
        sut.setSpeed(1.5)
        #expect(sut.player.defaultRate == 1.5)
        sut.setQuality(.maximum(height: 240))
        #expect(sut.player.currentItem?.preferredMaximumResolution.height == 240)
        #expect(sut.player.currentItem?.audioTimePitchAlgorithm == .timeDomain)
        sut.stop()
    }

    @Test func skipClampsToBounds() async throws {
        let sut = controller()
        sut.load(PlaybackItem(url: try await makeVideo(), title: "T"), autoplay: false)
        try await waitUntil { sut.duration > 1 }
        sut.skip(by: -10)
        #expect(sut.currentTime == 0)
        sut.skip(by: 10)
        #expect(sut.currentTime == sut.duration)
        sut.stop()
    }

    @Test func subtitleSelectionShowsCueAndOffClears() async throws {
        let sut = controller()
        sut.load(PlaybackItem(url: try await makeVideo(), title: "T", subtitles: [track()]), autoplay: false)
        sut.selectSubtitle(id: "ar")
        try await waitUntil { sut.currentCue?.text == "مرحبا" }
        sut.selectSubtitle(id: nil)
        #expect(sut.currentCue == nil)
        sut.stop()
    }

    @Test func currentChapterFollowsTime() async throws {
        let sut = controller()
        let chapters = [Chapter(id: "a", startTime: 0, title: "A"), Chapter(id: "b", startTime: 1, title: "B")]
        sut.load(PlaybackItem(url: try await makeVideo(), title: "T", chapters: chapters), autoplay: false)
        try await waitUntil { sut.duration > 1 }
        sut.seek(to: 1.5)
        #expect(sut.currentChapter?.id == "b")
        sut.stop()
    }
}

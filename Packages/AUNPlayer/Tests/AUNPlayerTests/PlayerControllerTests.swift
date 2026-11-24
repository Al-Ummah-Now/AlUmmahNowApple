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

    private func positions() -> PlaybackPositionStore {
        PlaybackPositionStore(defaults: UserDefaults(suiteName: "positions-\(UUID().uuidString)")!)
    }

    private func resumable(_ url: URL) -> PlaybackItem { PlaybackItem(url: url, title: "T", resumeID: "v1") }

    /// E20-A5: Screen Time can end the app with no warning; a new process comes back to where the video was.
    @Test func thePositionSurvivesTheAppBeingEndedWhilePlaying() async throws {
        let (url, store) = (try await makeVideo(seconds: 40), positions())
        let ended = PlayerController(subtitleLoader: { _ in "" }, positions: store)
        ended.load(resumable(url), autoplay: false)
        try await waitUntil { ended.phase == .ready && ended.duration > 30 }
        ended.seek(to: 20)
        #expect(store.position(of: "v1") == 20)

        // No pause and no stop: the first controller is simply gone.
        let next = PlayerController(subtitleLoader: { _ in "" }, positions: store)
        next.load(resumable(url), autoplay: false)
        #expect(next.currentTime == 20)
        try await waitUntil { next.phase == .ready && abs(next.player.currentTime().seconds - 20) < 0.5 }
        next.stop()
        ended.stop()
    }

    @Test func pausingKeepsTheExactPosition() async throws {
        let (url, store) = (try await makeVideo(seconds: 40), positions())
        let sut = PlayerController(subtitleLoader: { _ in "" }, positions: store)
        sut.load(resumable(url), autoplay: false)
        try await waitUntil { sut.phase == .ready && sut.duration > 30 }
        sut.seek(to: 12)
        sut.seek(to: 14)
        sut.stop()
        #expect(store.position(of: "v1") == 14)
    }

    @Test func anItemWithoutAResumeIDAndPrivateMediaKeepNothing() async throws {
        let (url, store) = (try await makeVideo(seconds: 40), positions())
        let live = PlayerController(subtitleLoader: { _ in "" }, positions: store)
        live.load(PlaybackItem(url: url, title: "T"), autoplay: false)
        let review = PlayerController(subtitleLoader: { _ in "" }, privateMedia: true, positions: store)
        review.load(resumable(url), autoplay: false)
        for sut in [live, review] {
            try await waitUntil { sut.phase == .ready && sut.duration > 30 }
            sut.seek(to: 20)
            sut.stop()
        }
        #expect(store.position(of: "v1") == nil)
    }

    /// The seek to the kept position is still on its way, so a tick at 0 is not where the person is.
    @Test func aTickBeforeTheResumeLandsIsIgnored() async throws {
        let (url, store) = (try await makeVideo(seconds: 40), positions())
        store.save(20, duration: 40, of: "v1")
        let sut = PlayerController(subtitleLoader: { _ in "" }, positions: store)
        sut.load(resumable(url), autoplay: true)
        // Nothing has been awaited since load, so the seek cannot have reported back yet.
        sut.applyTime(0)
        #expect(sut.currentTime == 20)
        try await waitUntil { sut.phase == .ready && sut.currentTime > 20 }
        sut.stop()
        #expect((store.position(of: "v1") ?? 0) >= 20)
    }

    /// Playing starts at once; the first ticks (at 0, before the seek lands) must not replace the kept position.
    @Test func autoplayResumesWithoutLosingTheKeptPosition() async throws {
        let (url, store) = (try await makeVideo(seconds: 40), positions())
        store.save(20, duration: 40, of: "v1")
        let sut = PlayerController(subtitleLoader: { _ in "" }, positions: store)
        sut.load(resumable(url), autoplay: true)
        for _ in 0..<100 where sut.player.currentTime().seconds < 20.3 {
            #expect((store.position(of: "v1") ?? 0) >= 20)
            #expect(sut.currentTime >= 20)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(sut.currentTime >= 20)
        sut.stop()
        #expect((store.position(of: "v1") ?? 0) >= 20)
    }

    @Test func pausingWhilePlayingSavesAtOnce() async throws {
        let (url, store) = (try await makeVideo(seconds: 40), positions())
        let sut = PlayerController(subtitleLoader: { _ in "" }, positions: store)
        sut.load(resumable(url), autoplay: false)
        try await waitUntil { sut.phase == .ready && sut.duration > 30 }
        sut.seek(to: 12)
        sut.play()
        try await waitUntil { sut.isPlaying && sut.currentTime > 12.3 }
        #expect(store.position(of: "v1") == 12)
        sut.pause()
        try await waitUntil { !sut.isPlaying && (store.position(of: "v1") ?? 0) > 12.3 }
        sut.stop()
    }
}

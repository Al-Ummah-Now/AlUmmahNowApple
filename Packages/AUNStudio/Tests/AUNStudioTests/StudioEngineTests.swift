import AUNCoreBridge
import AVFoundation
import Foundation
import Testing

@testable import AUNStudio

struct CSVWriterTests {
    @Test func startsWithABOMQuotesWhatNeedsItAndEndsLinesWithCRLF() {
        var csv = CSVWriter(header: ["العنوان", "Views"])
        csv.append(["تفسير، الجزء \"الأول\"", "1200"])
        csv.append(["line\nbreak", "-5"])
        #expect(csv.data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        #expect(csv.text == "العنوان,Views\r\n\"تفسير، الجزء \"\"الأول\"\"\",1200\r\n\"line\nbreak\",-5\r\n")
        #expect(String(data: csv.data.dropFirst(3), encoding: .utf8) == csv.text)
    }

    @Test func formulasAreDefusedAndNumbersHaveNoGrouping() {
        #expect(CSVWriter.field("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(CSVWriter.field("@sum") == "'@sum")
        #expect(CSVWriter.field("-oops") == "'-oops")
        #expect(CSVWriter.field("-12.5") == "-12.5")
        #expect(CSVWriter.number(1_234_567.891) == "1234567.89")
        #expect(CSVWriter.number(3600.0) == "3600")
    }

    @Test func datesAreISO() {
        let date = Date(timeIntervalSince1970: 1_794_000_000)
        #expect(CSVWriter.date(date) == "2026-11-06T21:20:00Z")
        #expect(CSVWriter.day(date) == "2026-11-06")
    }

    @Test func dailyExportKeepsOneRowPerDay() {
        let csv = AnalyticsCSV.daily(
            [DailyMetric(date: "2026-11-08", views: 5, likes: 1, comments: 2, subscribers: 3, watchTime: 600.5)],
            header: ["date", "views", "watchTime", "likes", "comments", "subscribers"])
        #expect(csv.rows.last == ["2026-11-08", "5", "600.5", "1", "2", "3"])
    }
}

struct SnapshotHistoryTests {
    @Test func undoRedoAndANewEditClearsRedo() {
        var history = SnapshotHistory("a")
        history.record("b")
        history.record("c")
        #expect(history.undo() == "b")
        #expect(history.undo() == "a")
        #expect(history.undo() == nil)
        #expect(history.redo() == "b")
        history.record("d")
        #expect(!history.canRedo)
        #expect(history.current == "d")
        history.record("d")
        #expect(history.undo() == "b")
    }

    @Test func boundedAndResettable() {
        var history = SnapshotHistory(0, limit: 3)
        for value in 1...10 { history.record(value) }
        var undone = 0
        while history.undo() != nil { undone += 1 }
        #expect(undone == 3)
        #expect(history.current == 7)
        history.reset(42)
        #expect(!history.canUndo && !history.canRedo && history.current == 42)
    }
}

/// A renditions server that records calls and answers as scripted.
private actor FakeRenditions: RenditionsServicing {
    var calls: [String] = []
    var createError: CoreError?
    var putFailures: [String: [CoreError]] = [:]
    var completeAnswers: [CoreError?] = []

    func script(create: CoreError? = nil, put: [String: [CoreError]] = [:], complete: [CoreError?] = []) {
        createError = create
        putFailures = put
        completeAnswers = complete
    }

    func createRenditions(
        videoID: String, rungs: [String], files: [StagedFile], encoder: String, channelID: String?
    ) async throws -> RenditionStaging {
        calls.append("create:\(rungs.joined(separator: ",")):\(files.count)")
        if let createError { throw createError }
        return RenditionStaging(stagingID: "s1", maxFileBytes: 1000)
    }

    func putRenditionFile(
        videoID: String, stagingID: String, file: StagedFile, bytes: Data, channelID: String?
    ) async throws {
        calls.append("put:\(file.path)")
        if var failures = putFailures[file.path], !failures.isEmpty {
            let error = failures.removeFirst()
            putFailures[file.path] = failures
            throw error
        }
    }

    func completeRenditions(videoID: String, stagingID: String, channelID: String?) async throws {
        calls.append("complete")
        if !completeAnswers.isEmpty, let error = completeAnswers.removeFirst() { throw error }
    }

    func cancelRenditions(videoID: String, stagingID: String, channelID: String?) async throws { calls.append("cancel") }
}

struct RenditionUploaderTests {
    private let files = [
        StagedFile(path: "360p/index.m3u8", bytes: 3), StagedFile(path: "360p/init.mp4", bytes: 2),
        StagedFile(path: "360p/seg_00001.m4s", bytes: 5),
    ]

    private func uploader(_ server: FakeRenditions) -> RenditionUploader {
        var uploader = RenditionUploader(
            service: server, videoID: "v1", channelID: "c1", root: URL(fileURLWithPath: "/staging"), rungs: ["360p"],
            files: files, encoder: "Studio for Mac")
        let sizes = Dictionary(uniqueKeysWithValues: files.map { ($0.path, Int($0.bytes)) })
        uploader.read = { url in
            let path = url.pathComponents.suffix(2).joined(separator: "/")
            return Data(repeating: 1, count: sizes[path] ?? 0)
        }
        uploader.pause = { _ in }
        return uploader
    }

    @Test func declaresPutsEveryFileThenCompletes() async {
        let server = FakeRenditions()
        let seen = LockedProgress()
        let outcome = await uploader(server).run { seen.append($0) }
        #expect(outcome == .ready)
        #expect(
            await server.calls == [
                "create:360p:3", "put:360p/index.m3u8", "put:360p/init.mp4", "put:360p/seg_00001.m4s", "complete",
            ])
        #expect(seen.values.last?.fraction == 1)
        #expect(seen.values.map(\.filesDone) == [1, 2, 3])
    }

    @Test func tooLateMeansTheServerEncodesAndNothingIsCancelled() async {
        let server = FakeRenditions()
        await server.script(create: .conflict("too_late"))
        #expect(await uploader(server).run() == .tooLate)
        #expect(await server.calls == ["create:360p:3"])
    }

    @Test func missingFilesAreSentAgain() async {
        let server = FakeRenditions()
        await server.script(complete: [.conflict("files_missing", missing: ["360p/init.mp4"]), nil])
        #expect(await uploader(server).run() == .ready)
        #expect(await server.calls.suffix(3) == ["complete", "put:360p/init.mp4", "complete"])
    }

    @Test func transientErrorsRetryAndFinalOnesCancelTheStaging() async {
        let server = FakeRenditions()
        await server.script(put: ["360p/init.mp4": [.http(status: 503), .offline]])
        #expect(await uploader(server).run() == .ready)
        #expect(await server.calls.filter { $0 == "put:360p/init.mp4" }.count == 3)

        let refusing = FakeRenditions()
        await refusing.script(put: ["360p/init.mp4": [.invalid("size_mismatch")]])
        guard case .failed = await uploader(refusing).run() else {
            Issue.record("expected a failure")
            return
        }
        #expect(await refusing.calls.last == "cancel")
    }

    @Test func cancellingStopsAndDropsTheStaging() async {
        let server = FakeRenditions()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await uploader(server).run()
        }
        #expect(await task.value == .cancelled)
        #expect(!(await server.calls.contains("complete")))
    }

    @Test func aFileOverTheServerLimitFailsBeforeSending() async {
        let server = FakeRenditions()
        var big = uploader(server)
        big = RenditionUploader(
            service: server, videoID: "v1", channelID: nil, root: URL(fileURLWithPath: "/s"), rungs: ["360p"],
            files: [StagedFile(path: "360p/seg_00001.m4s", bytes: 5000)], encoder: "x")
        guard case .failed = await big.run() else {
            Issue.record("expected a failure")
            return
        }
        #expect(await server.calls == ["create:360p:1", "cancel"])
    }
}

private final class LockedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RenditionUploader.Progress] = []
    func append(_ value: RenditionUploader.Progress) { lock.withLock { stored.append(value) } }
    var values: [RenditionUploader.Progress] { lock.withLock { stored } }
}

struct TimelineComposerTests {
    /// A one-second 64×64 movie with silent AAC audio, written locally.
    static func makeMovie(seconds: Double = 2) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "aun-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(video)
        guard writer.startWriting() else { throw CompositionError.empty }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * 10)
        for frame in 0..<frames {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CompositionError.empty }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        video.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @Test func placesClipsAtTheirTimelineStartAndScalesSpeed() async throws {
        let movie = try await Self.makeMovie()
        defer { try? FileManager.default.removeItem(at: movie) }
        let timeline = FlattenedTimeline(
            durationMs: 1500,
            tracks: [
                .init(
                    id: "v", kind: "video",
                    clips: [
                        .init(clipID: "a", sourceID: "s", path: movie.path, inMs: 0, outMs: 1000, timelineStartMs: 0),
                        .init(
                            clipID: "b", sourceID: "s", path: movie.path, inMs: 1000, outMs: 2000, timelineStartMs: 1000,
                            speed: 2),
                    ])
            ])
        let built = try await TimelineComposer.build(timeline)
        let duration = try await built.composition.load(.duration)
        #expect(abs(duration.seconds - 1.5) < 0.05)
        #expect(built.audioMix == nil)
    }

    @Test func anEmptyTimelineIsAnError() async {
        await #expect(throws: CompositionError.self) {
            _ = try await TimelineComposer.build(FlattenedTimeline(durationMs: 0, tracks: []))
        }
    }
}

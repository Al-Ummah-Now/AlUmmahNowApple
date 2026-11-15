import AUNCoreBridge
import AVFoundation
import Foundation
import Testing

@testable import AUNCoreKit

// The media adapters against the real Core release (no fakes): EDL edits, the server ladder, fMP4 packaging and the
// whisper model store. Nothing here downloads a model or calls a server.

struct CoreEDLEditingTests {
    let edl = CoreEDLEditing()

    static let project = """
        {"schemaVersion":1,"id":"p1","metadata":{"title":"Test","createdAtMs":0,"updatedAtMs":0},
         "settings":{"width":1280,"height":720,"fps":30.0,"sampleRate":48000,"channels":2},
         "sources":[{"id":"s1","path":"/media/one.mp4","durationMs":10000,
           "video":{"codec":"h264","width":1280,"height":720,"fps":30.0}}],
         "tracks":[{"id":"v1","kind":"video","clips":[]}]}
        """

    static let appendA = #"{"op":"append","trackId":"v1","clip":{"id":"a","sourceId":"s1","inMs":0,"outMs":10000}}"#

    private func clips(_ project: String) throws -> [FlattenedTimeline.Clip] {
        try edl.flatten(project: project).tracks.first?.clips ?? []
    }

    @Test func appendSplitJoinAndRippleDelete() throws {
        var project = try edl.apply(
            project: Self.project, op: Self.appendA)
        #expect(try clips(project).map(\.clipID) == ["a"])

        project = try edl.apply(project: project, op: #"{"op":"split","clipId":"a","atMs":4000,"newId":"b"}"#)
        let split = try clips(project)
        #expect(split.map(\.clipID) == ["a", "b"])
        #expect(split[1].inMs == 4000 && split[1].timelineStartMs == 4000)
        #expect(split[0].path == "/media/one.mp4")

        let joined = try edl.apply(project: project, op: #"{"op":"join","leftId":"a","rightId":"b"}"#)
        #expect(try clips(joined).map(\.outMs) == [10000])

        let deleted = try edl.apply(project: project, op: #"{"op":"rippleDeleteClip","clipId":"a"}"#)
        let remaining = try clips(deleted)
        #expect(remaining.map(\.clipID) == ["b"])
        #expect(remaining[0].timelineStartMs == 0)
        #expect(try edl.flatten(project: deleted).durationMs == 6000)
    }

    @Test func refusedEditsComeBackAsBridgeErrors() throws {
        let project = try edl.apply(
            project: Self.project, op: Self.appendA)
        #expect(throws: CoreError.self) {
            _ = try edl.apply(project: project, op: #"{"op":"split","clipId":"a","atMs":0,"newId":"b"}"#)
        }
        do {
            _ = try edl.apply(project: project, op: #"{"op":"split","clipId":"a","atMs":0,"newId":"b"}"#)
        } catch let error as CoreError {
            guard case .invalid = error else { return #expect(Bool(false), "expected invalid, got \(error)") }
        }
        #expect(throws: CoreError.notFound) {
            _ = try edl.apply(project: project, op: #"{"op":"rippleDeleteClip","clipId":"nope"}"#)
        }
    }

    /// The title ops as the Mac editor sends them (Core 0.4.0-rc.2): add to a title track, move/reword via setTitle,
    /// remove; the flattened titles carry the style back.
    @Test func titlesAddSetAndRemove() throws {
        var project = try edl.apply(project: Self.project, op: Self.appendA)
        project = project.replacingOccurrences(
            of: #"{"id":"v1""#, with: #"{"id":"titles","kind":"title"},{"id":"v1""#)
        let title = """
            {"id":"t-1","startMs":1000,"durationMs":4000,"text":{"ar":"الأمة الآن","en":"Al Ummah Now"},
             "style":{"fontFamily":"Noto Sans Arabic","sizePt":28,"color":"#f7f1e8","background":"#093041","position":"lowerThird"}}
            """
        project = try edl.apply(project: project, op: #"{"op":"addTitle","trackId":"titles","title":\#(title)}"#)
        var flat = try edl.flatten(project: project)
        let added = try #require(flat.titles.first)
        #expect(added.titleID == "t-1" && added.trackID == "titles" && added.startMs == 1000 && added.durationMs == 4000)
        #expect(added.text["ar"] == "الأمة الآن")
        #expect(added.style.position == .lowerThird && added.style.background == "#093041" && added.style.sizePt == 28)
        #expect(flat.durationMs == 10000)

        let moved = title.replacingOccurrences(of: #""startMs":1000"#, with: #""startMs":3000"#)
        project = try edl.apply(project: project, op: #"{"op":"setTitle","title":\#(moved)}"#)
        flat = try edl.flatten(project: project)
        #expect(flat.titles.map(\.startMs) == [3000])

        #expect(throws: CoreError.self) {
            _ = try edl.apply(project: project, op: #"{"op":"addTitle","trackId":"v1","title":\#(title)}"#)
        }
        let blank = title.replacingOccurrences(of: #""ar":"الأمة الآن","en":"Al Ummah Now""#, with: #""en":"""#)
        #expect(throws: CoreError.self) {
            _ = try edl.apply(project: project, op: #"{"op":"setTitle","title":\#(blank)}"#)
        }

        project = try edl.apply(project: project, op: #"{"op":"removeTitle","titleId":"t-1"}"#)
        #expect(try edl.flatten(project: project).titles.isEmpty)
    }

    @Test func loadKeepsTheProject() throws {
        let loaded = try edl.load(project: Self.project)
        #expect(try edl.flatten(project: loaded).tracks.map(\.id) == ["v1"])
    }
}

struct CoreRenditionPackagingTests {
    let packaging = CoreRenditionPackaging()

    @Test func theServerLadderLowestFirst() {
        let ladder = packaging.ladder(width: 1920, height: 1080, rotation: 0)
        #expect(ladder.first?.name == "360p")
        #expect(ladder.last?.name == "1080p")
        #expect(ladder.allSatisfy { $0.gopSeconds == 2 && $0.maxrate > 0 && $0.width % 2 == 0 && $0.height % 2 == 0 })
        let portrait = packaging.ladder(width: 1920, height: 1080, rotation: 90)
        #expect(portrait.allSatisfy { $0.height > $0.width })
        #expect(packaging.ladder(width: 0, height: 0, rotation: 0).isEmpty)
    }

    /// Six seconds of 64×64 H.264 with a keyframe every 2 s.
    static func makeMP4() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pkg-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
                AVVideoCompressionPropertiesKey: [
                    AVVideoMaxKeyFrameIntervalKey: 20, AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(video)
        guard writer.startWriting() else { throw CoreError.decoding }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CoreError.decoding }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        video.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @Test func packagesAnMP4AndListsTheFilesForTheServer() async throws {
        let mp4 = try await Self.makeMP4()
        let root = FileManager.default.temporaryDirectory.appending(path: "rungs-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: mp4)
            try? FileManager.default.removeItem(at: root)
        }
        let package = try await packaging.package(
            mp4: mp4, outputDirectory: root.appending(path: "360p"), segmentSeconds: 2)
        let names = package.files.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        #expect(names.contains("index.m3u8") && names.contains("init.mp4") && names.contains("seg_00001.m4s"))
        #expect(abs(package.durationMs - 6000) < 200)

        let files = try packaging.files(root: root, rungs: ["360p"])
        #expect(files.first?.path == "360p/index.m3u8")
        #expect(files.allSatisfy { $0.path.hasPrefix("360p/") && $0.bytes > 0 })
        #expect(files.count == package.files.count)
    }

    @Test func cancellingStopsPackaging() async throws {
        let mp4 = try await Self.makeMP4()
        defer { try? FileManager.default.removeItem(at: mp4) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await packaging.package(
                mp4: mp4, outputDirectory: FileManager.default.temporaryDirectory.appending(path: "c-\(UUID().uuidString)"),
                segmentSeconds: 2)
        }
        await #expect(throws: (any Error).self) { _ = try await task.value }
    }
}

struct CoreOnDeviceTranscriberTests {
    private func transcriber() -> CoreOnDeviceTranscriber {
        CoreOnDeviceTranscriber(directory: FileManager.default.temporaryDirectory.appending(path: "models-\(UUID().uuidString)"))
    }

    @Test func theMacSliceHasWhisperAndAModelCatalog() throws {
        let engine = transcriber()
        #if os(macOS)
            #expect(engine.isAvailable)
        #endif
        let models = try engine.models()
        #expect(!models.isEmpty)
        #expect(models.allSatisfy { !$0.installed && $0.sizeBytes > 0 })
    }

    @Test func transcribingWithoutTheModelIsNotFound() async {
        await #expect(throws: CoreError.notFound) {
            _ = try await transcriber().transcribe(
                model: "base-q5_1", media: URL(fileURLWithPath: "/nope.mp4"), language: "ar", progress: { _ in })
        }
    }

    @Test func segmentsDecodeInTheTranscriptBodyShape() throws {
        let segments = try CoreOnDeviceTranscriber.decodeSegments(#"[{"startMs":0,"endMs":1500,"text":"بسم الله"}]"#)
        #expect(segments == [TranscriptSegment(startMs: 0, endMs: 1500, text: "بسم الله")])
        #expect(throws: CoreError.decoding) { _ = try CoreOnDeviceTranscriber.decodeSegments("{}") }
    }
}

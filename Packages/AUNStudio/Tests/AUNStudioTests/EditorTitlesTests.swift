import AUNCoreBridge
import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import AUNStudio

/// Titles and lower thirds (E19 19.5 + 19.9): the ops the model sends, undo, the kit's style, and the renderer.
@MainActor
struct EditorTitlesTests {
    private let media = EditorSourceMedia(durationMs: 10_000, width: 1920, height: 1080, fps: 30, videoCodec: "avc1")
    private let kit = BrandKit(
        name: BrandKit.Name(en: "Al Ummah Now", ar: "الأمة الآن"),
        colors: BrandKit.Colors(primary: "#ffa037", secondary: "#093041", text: "#f7f1e8", background: "#093041"))

    private func editor(_ edl: FakeEDL = FakeEDL()) -> EditorModel {
        let model = EditorModel(edl: edl, store: nil)
        var next = 0
        model.makeID = {
            next += 1
            return "\(next)"
        }
        model.importClip(url: URL(fileURLWithPath: "/a.mp4"), media: media)
        return model
    }

    @Test func addingALowerThirdAddsTheTitleTrackAndOneUndoStep() throws {
        let edl = FakeEDL()
        let model = editor(edl)
        model.playheadMs = 2_000
        model.addTitle(
            position: .lowerThird, text: ["en": "Al Ummah Now", "ar": "الأمة الآن", "fr": " "], brand: TitleBrand(kit: kit))
        let op = try #require(edl.lastOp)
        #expect(op["op"] as? String == "addTitle")
        #expect(op["trackId"] as? String == EditorModel.titleTrack)
        let title = try #require(op["title"] as? [String: Any])
        #expect(title["startMs"] as? Int == 2_000)
        #expect(title["durationMs"] as? Int == EditorModel.titleDurationMs)
        #expect(title["text"] as? [String: String] == ["en": "Al Ummah Now", "ar": "الأمة الآن"])
        let style = try #require(title["style"] as? [String: Any])
        #expect(style["position"] as? String == "lowerThird")
        #expect(style["background"] as? String == "#093041")
        #expect(style["fontFamily"] as? String == TitleBrand.systemFont)
        let tracks = EditorModel.object(model.project)?["tracks"] as? [[String: Any]]
        #expect(tracks?.map { $0["kind"] as? String } == ["video", "title"])
        #expect(model.selectedTitle?.titleID == "t-3")
        #expect(model.titles(at: 3_000).count == 1)
        #expect(model.titles(at: 6_000).isEmpty)

        model.undo()
        #expect(model.titles.isEmpty)
        #expect(model.selection == nil)
        // The track went with the undo: it was added in the same step.
        #expect((EditorModel.object(model.project)?["tracks"] as? [[String: Any]])?.count == 1)
        model.redo()
        #expect(model.titles.map(\.titleID) == ["t-3"])
    }

    @Test func aSecondTitleReusesTheTrackAndStaysInsideTheTimeline() throws {
        let edl = FakeEDL()
        let model = editor(edl)
        model.addTitle(position: .center, text: ["en": "One"], brand: TitleBrand())
        model.playheadMs = 9_000
        model.addTitle(position: .center, text: ["ar": "اثنان"], brand: TitleBrand())
        let tracks = EditorModel.object(model.project)?["tracks"] as? [[String: Any]]
        #expect(tracks?.filter { $0["kind"] as? String == "title" }.count == 1)
        let last = try #require(model.titles.last)
        #expect(last.startMs == 9_000)
        #expect(last.durationMs == 1_000)
        #expect(last.style.background == nil)
        #expect(last.style.sizePt == TitleBrand.titleSizePt)
    }

    @Test func titlesNeedAClipAndText() {
        let edl = FakeEDL()
        let empty = EditorModel(edl: edl, store: nil)
        empty.addTitle(position: .center, text: ["en": "Hi"], brand: TitleBrand())
        #expect(empty.titles.isEmpty)
        let model = editor(edl)
        model.addTitle(position: .center, text: ["en": "  "], brand: TitleBrand())
        #expect(model.problem == "studio.editor.titles.error.text")
        #expect(!edl.ops.contains("addTitle"))
    }

    @Test func moveRetimeRewordAndRemoveGoThroughSetTitle() throws {
        let edl = FakeEDL()
        let model = editor(edl)
        model.addTitle(position: .lowerThird, text: ["en": "Name"], brand: TitleBrand(kit: kit))
        let id = try #require(model.selection)

        model.nudge(id, by: 1_000)
        #expect(edl.lastOp?["op"] as? String == "setTitle")
        #expect(model.selectedTitle?.startMs == 1_000)

        model.moveTitle(id, toMs: -500)
        #expect(model.selectedTitle?.startMs == 0)

        model.retimeTitle(id, startMs: 2_000, durationMs: 100)
        #expect(model.selectedTitle?.startMs == 2_000)
        #expect(model.selectedTitle?.durationMs == EditorModel.minTitleMs)
        model.resizeTitle(id, by: 1_500)
        #expect(model.selectedTitle?.durationMs == 2_000)

        model.setTitleText(id, text: ["en": "", "ar": "اسم"])
        #expect(model.selectedTitle?.text == ["ar": "اسم"])
        model.setTitleText(id, text: ["en": " ", "ar": ""])
        #expect(model.problem == "studio.editor.titles.error.text")
        #expect(model.selectedTitle?.text == ["ar": "اسم"])

        model.setTitlePosition(id, .top, brand: TitleBrand(kit: kit))
        #expect(model.selectedTitle?.style.position == .top)
        #expect(model.selectedTitle?.style.background == nil)

        let steps = edl.ops.count
        model.undo()
        #expect(model.selectedTitle?.style.position == .lowerThird)
        model.redo()
        #expect(edl.ops.count == steps)

        model.rippleDelete()
        #expect(edl.lastOp?["op"] as? String == "removeTitle")
        #expect(edl.lastOp?["titleId"] as? String == id)
        #expect(model.titles.isEmpty)
        #expect(model.selection == nil)
        // Deleting a title never ripples the clips.
        #expect(model.clips.count == 1)
    }

    @Test func aRefusedTitleEditLeavesTheProject() throws {
        let edl = FakeEDL()
        let model = editor(edl)
        model.addTitle(position: .center, text: ["en": "One"], brand: TitleBrand())
        let before = model.project
        edl.refuse = ["setTitle"]
        model.resizeTitle(try #require(model.selection), by: 1_000)
        #expect(model.project == before)
        #expect(model.problem == "studio.editor.error.refused")
    }

    @Test func applyBrandRestylesFromTheCurrentKit() throws {
        let edl = FakeEDL()
        let model = editor(edl)
        model.addTitle(position: .lowerThird, text: ["en": "Name"], brand: TitleBrand(kit: kit))
        let id = try #require(model.selection)
        var boxed = kit
        boxed.lowerThird.style = .box
        model.applyBrand(id, brand: TitleBrand(kit: boxed))
        #expect(model.selectedTitle?.style.background == "#ffa037")
        // Parchment text is unreadable on the lantern orange, so the kit's dark teal is used.
        #expect(model.selectedTitle?.style.color == "#093041")
        let count = edl.ops.count
        model.applyBrand(id, brand: TitleBrand(kit: boxed))
        #expect(edl.ops.count == count)
    }

    @Test func minimalLowerThirdsHaveNoBox() {
        var minimal = kit
        minimal.lowerThird.style = .minimal
        let style = TitleBrand(kit: minimal).style(for: .lowerThird)
        #expect(style.background == nil)
        #expect(style.color == kit.colors.text)
    }

    @Test func linesAreArabicThenEnglishOnEveryApp() {
        let title = FlattenedTimeline.Title(
            titleID: "t", trackID: "t1", startMs: 0, durationMs: 1_000,
            text: ["en": "Name", "fr": "Nom", "ar": "اسم", "de": ""],
            style: TitleBrand().style(for: .lowerThird))
        #expect(title.lines.map(\.locale) == ["ar", "en", "fr"])
    }

    @Test func theFlattenedTitlesDecodeFromCoresShape() throws {
        let json = """
            {"durationMs":5000,"tracks":[],"titles":[{"titleId":"t-1","trackId":"t1","startMs":500,"durationMs":2000,
            "text":{"ar":"اسم"},"style":{"fontFamily":"system","sizePt":44.0,"color":"#ffffff","position":"lowerThird"}}]}
            """
        let timeline = try FlattenedTimeline.decode(json)
        #expect(timeline.titles.first?.style.position == .lowerThird)
        #expect(timeline.titles.first?.endMs == 2_500)
        #expect(try FlattenedTimeline.decode(#"{"durationMs":0,"tracks":[]}"#).titles.isEmpty)
    }
}

/// The renderer the preview and the export share.
struct TitleRendererTests {
    private let canvas = CGSize(width: 1280, height: 720)
    private let kit = BrandKit(
        name: BrandKit.Name(en: "Al Ummah Now", ar: "الأمة الآن"),
        colors: BrandKit.Colors(primary: "#ffa037", secondary: "#093041", text: "#f7f1e8", background: "#093041"))

    private func title(_ text: [String: String], _ position: FlattenedTimeline.TitleStyle.Position, kit: BrandKit)
        -> FlattenedTimeline.Title
    {
        FlattenedTimeline.Title(
            titleID: "t", trackID: "t1", startMs: 0, durationMs: 1_000, text: text,
            style: TitleBrand(kit: kit).style(for: position))
    }

    @Test func lowerThirdsStartOnTheTitlesOwnReadingSide() throws {
        let brand = TitleBrand(kit: kit)
        let english = try #require(
            TitleRenderer.layout(title(["en": "Al Ummah Now"], .lowerThird, kit: kit), brand: brand, canvas: canvas))
        let arabic = try #require(
            TitleRenderer.layout(title(["ar": "الأمة الآن"], .lowerThird, kit: kit), brand: brand, canvas: canvas))
        #expect(!english.rightToLeft && english.box.minX < canvas.width / 2 && english.box.maxX < canvas.width * 0.8)
        #expect(arabic.rightToLeft && arabic.box.maxX > canvas.width / 2 && arabic.box.minX > canvas.width * 0.2)
        #expect(english.box.maxY < canvas.height * 0.9 && english.box.minY > canvas.height * 0.6)

        var centred = kit
        centred.lowerThird.position = .center
        let middle = try #require(
            TitleRenderer.layout(
                title(["ar": "الأمة الآن"], .lowerThird, kit: centred), brand: TitleBrand(kit: centred), canvas: canvas))
        #expect(abs(middle.box.midX - canvas.width / 2) < 1)
    }

    @Test func titlesSitWhereTheirPositionSays() throws {
        let brand = TitleBrand(kit: kit)
        let top = try #require(TitleRenderer.layout(title(["en": "Top"], .top, kit: kit), brand: brand, canvas: canvas))
        let centre = try #require(TitleRenderer.layout(title(["en": "Centre"], .center, kit: kit), brand: brand, canvas: canvas))
        #expect(top.box.maxY < canvas.height / 3)
        #expect(abs(centre.box.midY - canvas.height / 2) < 1)
        #expect(abs(centre.box.midX - canvas.width / 2) < 1)
        #expect(TitleRenderer.layout(title(["en": " "], .center, kit: kit), brand: brand, canvas: canvas) == nil)
    }

    @Test func aLongLineIsCutToTheFrame() throws {
        let long = String(repeating: "الأمة الآن ", count: 40)
        let layout = try #require(
            TitleRenderer.layout(title(["ar": long], .lowerThird, kit: kit), brand: TitleBrand(kit: kit), canvas: canvas))
        #expect(layout.box.width <= canvas.width * 0.9)
    }

    @Test func drawsTheBoxInTheKitColourAndLeavesTheRestClear() throws {
        let brand = TitleBrand(kit: kit)
        let lower = title(["en": "Al Ummah Now"], .lowerThird, kit: kit)
        let image = try #require(TitleRenderer.image(lower, brand: brand, canvas: canvas))
        let layout = try #require(TitleRenderer.layout(lower, brand: brand, canvas: canvas))
        let pixels = try Pixels(image)
        // Inside the box, just in from its end edge (no text there): the kit's secondary colour.
        let inside = pixels.rgba(x: Int(layout.box.maxX) - 4, y: Int(layout.box.midY))
        #expect(abs(Int(inside.r) - 0x09) < 12 && abs(Int(inside.g) - 0x30) < 12 && abs(Int(inside.b) - 0x41) < 12)
        #expect(inside.a > 200)
        // The bar style's accent stripe sits on the start edge.
        let stripe = pixels.rgba(x: Int(layout.box.minX) + 1, y: Int(layout.box.midY))
        #expect(stripe.r > 200 && stripe.g > 120)
        #expect(pixels.rgba(x: 10, y: 10).a == 0)
    }
}

/// Export draws the titles into the picture (AVFoundation composition with the renderer's images).
struct TitleExportTests {
    @Test func theExportShowsTheTitleOnlyWhileItIsOn() async throws {
        let movie = try await Self.makeBlueMovie()
        defer { try? FileManager.default.removeItem(at: movie) }
        let output = FileManager.default.temporaryDirectory.appending(path: "aun-titles-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        // A title so big its white box covers the whole 64×64 frame.
        let title = FlattenedTimeline.Title(
            titleID: "t", trackID: "t1", startMs: 1_000, durationMs: 1_000, text: ["en": "W"],
            style: .init(
                fontFamily: TitleBrand.systemFont, sizePt: 600, color: "#000000", background: "#ffffff", position: .center))
        let timeline = FlattenedTimeline(
            durationMs: 2_000,
            tracks: [
                .init(
                    id: "v", kind: "video",
                    clips: [.init(clipID: "a", sourceID: "s", path: movie.path, inMs: 0, outMs: 2_000, timelineStartMs: 0)])
            ],
            titles: [title])
        try await TimelineComposer.export(timeline, to: output, fps: 10)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func corner(at seconds: Double) async throws -> Pixels.RGBA {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            // The box's padding, left of the text: white while the title is on, the blue movie before and after.
            let pixels = try Pixels(image)
            return pixels.rgba(x: 2, y: pixels.height / 2)
        }
        let before = try await corner(at: 0.4)
        let during = try await corner(at: 1.5)
        #expect(before.r < 80 && before.b > 150, "\(before) \(during)")
        #expect(during.r > 200 && during.g > 200 && during.b > 200)
    }
}

extension TitleExportTests {
    /// A two-second 128×128 solid blue movie.
    static func makeBlueMovie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "aun-blue-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(video)
        guard writer.startWriting() else { throw CompositionError.empty }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 128, 128, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CompositionError.empty }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let row = CVPixelBufferGetBytesPerRow(buffer)
                let pixels = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<128 {
                    for x in 0..<128 {
                        let i = y * row + x * 4
                        (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) = (255, 0, 0, 255)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        video.markAsFinished()
        await writer.finishWriting()
        return url
    }
}

/// An image's pixels as RGBA bytes, top row first.
struct Pixels {
    struct RGBA {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
    }

    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let (width, height) = (image.width, image.height)
        self.width = width
        self.height = height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw CompositionError.empty }
        bytes = data
    }

    func rgba(x: Int, y: Int) -> RGBA {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return RGBA(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3])
    }
}

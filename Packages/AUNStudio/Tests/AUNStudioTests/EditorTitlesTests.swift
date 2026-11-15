import AUNCoreBridge
import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import AUNStudio

/// Titles and lower thirds (E19 19.5 + 19.9): the ops the model sends, the rules shared with Desktop, undo, the kit's
/// style, and the renderer.
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
        model.addTitle(.lowerThird, text: ["en": " Al Ummah Now ", "ar": "الأمة الآن", "fr": " "], brand: TitleBrand(kit: kit))
        let op = try #require(edl.lastOp)
        #expect(op["op"] as? String == "addTitle")
        #expect(op["trackId"] as? String == "titles")
        let title = try #require(op["title"] as? [String: Any])
        #expect(title["id"] as? String == "title-3")
        #expect(title["startMs"] as? Int == 2_000)
        #expect(title["durationMs"] as? Int == 4_000)
        #expect(title["text"] as? [String: String] == ["en": "Al Ummah Now", "ar": "الأمة الآن"])
        let style = try #require(title["style"] as? [String: Any])
        #expect(style["position"] as? String == "lowerThird")
        #expect(style["background"] as? String == "#093041")
        #expect(style["color"] as? String == "#f7f1e8")
        #expect(style["fontFamily"] as? String == "Noto Sans Arabic")
        #expect(style["sizePt"] as? Double == 28)
        let tracks = EditorModel.object(model.project)?["tracks"] as? [[String: Any]]
        #expect(tracks?.map { $0["kind"] as? String } == ["video", "title"])
        #expect(model.selectedTitle?.titleID == "title-3")
        #expect(model.titles(at: 3_000).count == 1)
        #expect(model.titles(at: 6_000).isEmpty)

        model.undo()
        #expect(model.titles.isEmpty)
        #expect(model.selection == nil)
        // The track went with the undo: it was added in the same step.
        #expect((EditorModel.object(model.project)?["tracks"] as? [[String: Any]])?.count == 1)
        model.redo()
        #expect(model.titles.map(\.titleID) == ["title-3"])
    }

    @Test func aNewTitleStopsAtTheNextTitleAndTheEndOfTheVideo() throws {
        let edl = FakeEDL()
        let model = editor(edl)
        model.playheadMs = 3_000
        model.addTitle(.title, text: ["en": "One"], brand: TitleBrand())
        model.playheadMs = 1_000
        #expect(model.canAddTitle)
        model.addTitle(.title, text: ["ar": "اثنان"], brand: TitleBrand())
        #expect(model.selectedTitle?.durationMs == 2_000)
        model.playheadMs = 9_500
        model.addTitle(.title, text: ["en": "Three"], brand: TitleBrand())
        #expect(model.selectedTitle?.durationMs == 500)
        #expect(model.selectedTitle?.style.background == nil)
        #expect(model.selectedTitle?.style.position == .center)
        #expect(model.selectedTitle?.style.sizePt == 44)
        let tracks = EditorModel.object(model.project)?["tracks"] as? [[String: Any]]
        #expect(tracks?.filter { $0["kind"] as? String == "title" }.count == 1)

        // No room: on a title, or less than 0.1 s of video left.
        model.playheadMs = 4_000
        #expect(!model.canAddTitle)
        model.addTitle(.title, text: ["en": "Four"], brand: TitleBrand())
        #expect(model.problem == "studio.editor.titles.error.room")
        model.playheadMs = 9_950
        model.addTitle(.title, text: ["en": "Five"], brand: TitleBrand())
        #expect(model.titles.count == 3)
    }

    @Test func titlesNeedAClipAndText() {
        let edl = FakeEDL()
        let empty = EditorModel(edl: edl, store: nil)
        empty.addTitle(.title, text: ["en": "Hi"], brand: TitleBrand())
        #expect(empty.titles.isEmpty && !empty.canAddTitle)
        let model = editor(edl)
        model.addTitle(.title, text: ["en": "  "], brand: TitleBrand())
        #expect(model.problem == "studio.editor.titles.error.text")
        #expect(!edl.ops.contains("addTitle"))
    }

    @Test func moveAndRetimeStayInsideTheVideoAndNeverOverlap() throws {
        let edl = FakeEDL()
        let model = editor(edl)
        model.addTitle(.lowerThird, text: ["en": "Name"], brand: TitleBrand(kit: kit))
        let id = try #require(model.selection)

        model.nudge(id, by: 1_000)
        #expect(edl.lastOp?["op"] as? String == "setTitle")
        #expect(model.selectedTitle?.startMs == 1_000)
        model.moveTitle(id, toMs: -500)
        #expect(model.selectedTitle?.startMs == 0)
        model.moveTitle(id, toMs: 9_000)
        #expect(model.selectedTitle?.startMs == 6_000)
        #expect(model.selectedTitle?.endMs == 10_000)

        model.retimeTitle(id, startMs: 5_000, endMs: 12_000)
        #expect(model.selectedTitle?.startMs == 5_000 && model.selectedTitle?.endMs == 10_000)
        model.retimeTitle(id, startMs: 5_000, endMs: 5_050)
        #expect(model.problem == "studio.editor.titles.error.length")

        model.playheadMs = 1_000
        model.addTitle(.title, text: ["en": "Other"], brand: TitleBrand())
        let other = try #require(model.selection)
        model.moveTitle(other, toMs: 4_000)
        #expect(model.problem == "studio.editor.titles.error.overlap")
        #expect(model.selectedTitle?.startMs == 1_000)

        model.selection = id
        model.playheadMs = 7_000
        model.titleEdgeToPlayhead(id, start: false)
        #expect(model.selectedTitle?.startMs == 5_000 && model.selectedTitle?.endMs == 7_000)
        model.playheadMs = 6_000
        model.titleEdgeToPlayhead(id, start: true)
        #expect(model.selectedTitle?.startMs == 6_000 && model.selectedTitle?.endMs == 7_000)
    }

    @Test func rewordChangeKindAndRemove() throws {
        let edl = FakeEDL()
        let model = editor(edl)
        model.addTitle(.lowerThird, text: ["en": "Name", "fr": "Nom"], brand: TitleBrand(kit: kit))
        let id = try #require(model.selection)

        model.setTitleText(id, text: ["en": "", "ar": " اسم "])
        // Other languages the title carries stay.
        #expect(model.selectedTitle?.text == ["ar": "اسم", "fr": "Nom"])
        model.setTitleText(id, text: ["ar": " ", "fr": ""])
        #expect(model.problem == "studio.editor.titles.error.text")
        #expect(model.selectedTitle?.text == ["ar": "اسم", "fr": "Nom"])

        model.setTitleKind(id, .title, brand: TitleBrand(kit: kit))
        #expect(model.selectedTitle?.kind == .title)
        #expect(model.selectedTitle?.style.background == nil)

        let steps = edl.ops.count
        model.undo()
        #expect(model.selectedTitle?.kind == .lowerThird)
        model.redo()
        #expect(edl.ops.count == steps)

        model.rippleDelete()
        #expect(edl.lastOp?["op"] as? String == "removeTitle")
        #expect(edl.lastOp?["titleId"] as? String == id)
        #expect(model.titles.isEmpty)
        #expect(model.selection == nil)
        #expect(model.clips.count == 1)
    }

    @Test func deletingAClipWithTitlesCutsItsSpanFromEveryTrack() throws {
        let edl = FakeEDL()
        let model = editor(edl)
        model.addTitle(.title, text: ["en": "One"], brand: TitleBrand())
        model.selection = "c-2"
        model.rippleDelete()
        #expect(edl.lastOp?["op"] as? String == "rippleDeleteRange")
        #expect(edl.lastOp?["startMs"] as? Int == 0)
        #expect(edl.lastOp?["endMs"] as? Int == 10_000)
    }

    @Test func aRefusedTitleEditLeavesTheProject() throws {
        let edl = FakeEDL()
        let model = editor(edl)
        model.addTitle(.title, text: ["en": "One"], brand: TitleBrand())
        let before = model.project
        edl.refuse = ["setTitle"]
        model.moveTitle(try #require(model.selection), toMs: 2_000)
        #expect(model.project == before)
        #expect(model.problem == "studio.editor.error.refused")
    }

    @Test func kitTemplatesMatchDesktop() {
        var box = kit
        box.lowerThird.style = .box
        #expect(TitleBrand(kit: box).style(for: .lowerThird).background == "#ffa037")
        var minimal = kit
        minimal.lowerThird.style = .minimal
        #expect(TitleBrand(kit: minimal).style(for: .lowerThird).background == nil)
        var broken = kit
        broken.colors.text = "nope"
        #expect(TitleBrand(kit: broken).style(for: .title).color == BrandKit.defaultColors.text)
    }

    @Test func linesAreArabicThenEnglishOnEveryApp() {
        let title = FlattenedTimeline.Title(
            titleID: "t", trackID: "titles", startMs: 0, durationMs: 1_000,
            text: ["en": "Name", "fr": "Nom", "ar": "اسم", "de": ""], style: TitleBrand().style(for: .lowerThird))
        #expect(title.lines.map(\.locale) == ["ar", "en", "fr"])
        #expect(TitleRenderer.isRightToLeft("  «اسم» Name"))
        #expect(!TitleRenderer.isRightToLeft("1. Name اسم"))
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

/// The renderer the preview and the export share; geometry as Desktop's `TitleLayout`.
struct TitleRendererTests {
    private let canvas = CGSize(width: 1280, height: 720)
    private let kit = BrandKit(
        name: BrandKit.Name(en: "Al Ummah Now", ar: "الأمة الآن"),
        colors: BrandKit.Colors(primary: "#ffa037", secondary: "#093041", text: "#f7f1e8", background: "#093041"))

    private func title(_ text: [String: String], _ kind: EditorTitleKind, kit: BrandKit) -> FlattenedTimeline.Title {
        FlattenedTimeline.Title(
            titleID: "t", trackID: "titles", startMs: 0, durationMs: 1_000, text: text,
            style: TitleBrand(kit: kit).style(for: kind))
    }

    @Test func lowerThirdsStartOnTheTitlesOwnReadingSide() throws {
        let brand = TitleBrand(kit: kit)
        let english = try #require(
            TitleRenderer.layout(title(["en": "Al Ummah Now"], .lowerThird, kit: kit), brand: brand, canvas: canvas))
        let arabic = try #require(
            TitleRenderer.layout(title(["ar": "الأمة الآن"], .lowerThird, kit: kit), brand: brand, canvas: canvas))
        // 5% safe margin on the start side; 8% from the bottom; the bar is at least 45% wide.
        #expect(!english.rightToLeft && abs(english.box.minX - 64) < 0.5)
        #expect(arabic.rightToLeft && abs(arabic.box.maxX - (1280 - 64)) < 0.5)
        #expect(abs(english.box.maxY - 720 * 0.92) < 0.5)
        #expect(english.box.width >= 1280 * 0.45 - 0.5)

        var centred = kit
        centred.lowerThird.position = .center
        let middle = try #require(
            TitleRenderer.layout(
                title(["ar": "الأمة الآن"], .lowerThird, kit: centred), brand: TitleBrand(kit: centred), canvas: canvas))
        #expect(abs(middle.box.midX - canvas.width / 2) < 1)
        var end = kit
        end.lowerThird.position = .end
        let englishAtEnd = try #require(
            TitleRenderer.layout(title(["en": "Name"], .lowerThird, kit: end), brand: TitleBrand(kit: end), canvas: canvas))
        #expect(abs(englishAtEnd.box.maxX - (1280 - 64)) < 0.5)
    }

    @Test func titlesSitWhereTheirKindSays() throws {
        let brand = TitleBrand(kit: kit)
        let centre = try #require(TitleRenderer.layout(title(["en": "Centre"], .title, kit: kit), brand: brand, canvas: canvas))
        #expect(abs(centre.box.midY - canvas.height / 2) < 1)
        #expect(abs(centre.box.midX - canvas.width / 2) < 1)
        #expect(!centre.hasBox)
        #expect(TitleRenderer.layout(title(["en": " "], .title, kit: kit), brand: brand, canvas: canvas) == nil)
        // 28 pt on a 720-line picture is 37.3 px, as on Desktop.
        #expect(abs(TitleRenderer.fontPixels(28, height: 720) - 37.333) < 0.01)
    }

    @Test func aLongLowerThirdWrapsInsideItsShare() throws {
        let long = String(repeating: "الأمة الآن ", count: 30)
        let layout = try #require(
            TitleRenderer.layout(title(["ar": long], .lowerThird, kit: kit), brand: TitleBrand(kit: kit), canvas: canvas))
        #expect(layout.box.width <= canvas.width * 0.62 + 1)
        #expect(layout.box.height > TitleRenderer.fontPixels(28, height: 720) * 2)
    }

    @Test func drawsTheBoxInTheKitColourAndLeavesTheRestClear() throws {
        let brand = TitleBrand(kit: kit)
        let lower = title(["en": "Al Ummah Now"], .lowerThird, kit: kit)
        let image = try #require(TitleRenderer.image(lower, brand: brand, canvas: canvas))
        let layout = try #require(TitleRenderer.layout(lower, brand: brand, canvas: canvas))
        let pixels = try Pixels(image)
        // Inside the bar, near its end edge (no text there): the kit's secondary colour.
        let inside = pixels.rgba(x: Int(layout.box.maxX) - 4, y: Int(layout.box.midY))
        #expect(abs(Int(inside.r) - 0x09) < 12 && abs(Int(inside.g) - 0x30) < 12 && abs(Int(inside.b) - 0x41) < 12)
        #expect(inside.a > 200)
        // The bar's accent stripe sits on the start edge.
        let stripe = pixels.rgba(x: Int(layout.box.minX) + 1, y: Int(layout.box.midY))
        #expect(stripe.r > 200 && stripe.g > 120)
        #expect(pixels.rgba(x: 10, y: 10).a == 0)
    }

    @Test func anArabicLowerThirdHasItsStripeOnTheRight() throws {
        let brand = TitleBrand(kit: kit)
        let lower = title(["ar": "الأمة الآن", "en": "Al Ummah Now"], .lowerThird, kit: kit)
        let pixels = try Pixels(try #require(TitleRenderer.image(lower, brand: brand, canvas: canvas)))
        let layout = try #require(TitleRenderer.layout(lower, brand: brand, canvas: canvas))
        let stripe = pixels.rgba(x: Int(layout.box.maxX) - 2, y: Int(layout.box.midY))
        #expect(stripe.r > 200 && stripe.g > 120)
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
                fontFamily: TitleBrand.fontFamily, sizePt: 600, color: "#000000", background: "#ffffff", position: .center))
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

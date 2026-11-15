import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

/// An EDL engine that keeps clips in the project JSON and applies the ops the model sends with simple rules, so the
/// model's op JSON, undo/redo and refusals can be checked without Core (AUNCoreKit's tests cover Core itself).
final class FakeEDL: EDLEditing, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [[String: Any]] = []
    var refuse: Set<String> = []

    var ops: [String] { lock.withLock { sent.compactMap { $0["op"] as? String } } }
    var lastOp: [String: Any]? { lock.withLock { sent.last } }

    func apply(project: String, op: String) throws -> String {
        guard var object = EditorModel.object(project),
            let edit = (try? JSONSerialization.jsonObject(with: Data(op.utf8))) as? [String: Any],
            let name = edit["op"] as? String
        else { throw CoreError.decoding }
        lock.withLock { sent.append(edit) }
        if refuse.contains(name) { throw CoreError.invalid("refused") }
        var clips = (object["clips"] as? [[String: Any]]) ?? []
        switch name {
        case "append":
            guard var clip = edit["clip"] as? [String: Any] else { throw CoreError.decoding }
            let end = clips.map { ($0["start"] as? Int ?? 0) + ($0["outMs"] as? Int ?? 0) - ($0["inMs"] as? Int ?? 0) }.max() ?? 0
            clip["start"] = end
            clips.append(clip)
        case "split":
            guard let index = clips.firstIndex(where: { $0["id"] as? String == edit["clipId"] as? String }),
                let at = edit["atMs"] as? Int
            else { throw CoreError.notFound }
            var left = clips[index]
            var right = left
            let start = left["start"] as? Int ?? 0
            let cut = (left["inMs"] as? Int ?? 0) + at - start
            left["outMs"] = cut
            right["id"] = edit["newId"]
            right["inMs"] = cut
            right["start"] = at
            clips[index] = left
            clips.insert(right, at: index + 1)
        case "rippleDeleteClip":
            clips.removeAll { $0["id"] as? String == edit["clipId"] as? String }
        case "move", "trim", "join":
            break
        case "addTitle", "setTitle":
            guard var title = edit["title"] as? [String: Any] else { throw CoreError.decoding }
            let tracks = (object["tracks"] as? [[String: Any]]) ?? []
            var titles = (object["titles"] as? [[String: Any]]) ?? []
            if name == "addTitle" {
                guard
                    tracks.contains(where: {
                        $0["id"] as? String == edit["trackId"] as? String && $0["kind"] as? String == "title"
                    })
                else { throw CoreError.invalid("not a title track") }
                title["trackId"] = edit["trackId"]
            } else {
                guard let old = titles.first(where: { $0["id"] as? String == title["id"] as? String }) else {
                    throw CoreError.notFound
                }
                title["trackId"] = old["trackId"]
            }
            titles.removeAll { $0["id"] as? String == title["id"] as? String }
            titles.append(title)
            object["titles"] = titles
        case "removeTitle":
            var titles = (object["titles"] as? [[String: Any]]) ?? []
            guard titles.contains(where: { $0["id"] as? String == edit["titleId"] as? String }) else { throw CoreError.notFound }
            titles.removeAll { $0["id"] as? String == edit["titleId"] as? String }
            object["titles"] = titles
        default:
            throw CoreError.invalid(name)
        }
        object["clips"] = clips
        object["rev"] = (object["rev"] as? Int ?? 0) + 1
        return try EditorModel.json(object)
    }

    func flatten(project: String) throws -> FlattenedTimeline {
        let clips = (EditorModel.object(project)?["clips"] as? [[String: Any]]) ?? []
        let flat = clips.map {
            FlattenedTimeline.Clip(
                clipID: $0["id"] as? String ?? "", sourceID: $0["sourceId"] as? String ?? "", path: "/x.mp4",
                inMs: $0["inMs"] as? Int ?? 0, outMs: $0["outMs"] as? Int ?? 0, timelineStartMs: $0["start"] as? Int ?? 0)
        }
        let end = flat.map { $0.timelineStartMs + $0.timelineDurationMs }.max() ?? 0
        let rawTitles = (EditorModel.object(project)?["titles"] as? [[String: Any]]) ?? []
        let titles = try rawTitles.map { raw -> FlattenedTimeline.Title in
            var flat = raw
            flat["titleId"] = raw["id"]
            flat.removeValue(forKey: "id")
            return try JSONDecoder().decode(FlattenedTimeline.Title.self, from: JSONSerialization.data(withJSONObject: flat))
        }
        .sorted { $0.startMs < $1.startMs }
        return FlattenedTimeline(
            durationMs: end, tracks: [.init(id: EditorModel.videoTrack, kind: "video", clips: flat)], titles: titles)
    }
}

@MainActor
struct EditorModelTests {
    private func model(_ edl: FakeEDL = FakeEDL(), store: EditorProjectStore? = nil) -> EditorModel {
        let model = EditorModel(edl: edl, store: store)
        var next = 0
        model.makeID = {
            next += 1
            return "\(next)"
        }
        return model
    }

    private let media = EditorSourceMedia(durationMs: 6_000, width: 1280, height: 720, fps: 30, videoCodec: "avc1")

    @Test func importAddsTheSourceAndAppendsOneUndoStep() throws {
        let edl = FakeEDL()
        let editor = model(edl)
        editor.importClip(url: URL(fileURLWithPath: "/media/One.mp4"), media: media)
        #expect(editor.clips.map(\.clipID) == ["c-2"])
        #expect(editor.selection == "c-2")
        #expect(editor.sourceNames["s-1"] == "One.mp4")
        #expect(editor.sourceDurations["s-1"] == 6_000)
        let append = try #require(edl.lastOp)
        #expect(append["trackId"] as? String == "v1")
        #expect((append["clip"] as? [String: Any])?["outMs"] as? Int == 6_000)
        let settings = EditorModel.object(editor.project)?["settings"] as? [String: Any]
        #expect(settings?["width"] as? Int == 1280)
        editor.undo()
        #expect(editor.isEmpty && !editor.canUndo && editor.canRedo)
        editor.redo()
        #expect(editor.clips.count == 1)
    }

    @Test func splitAtThePlayheadThenUndoRedo() throws {
        let edl = FakeEDL()
        let editor = model(edl)
        editor.importClip(url: URL(fileURLWithPath: "/a.mp4"), media: media)
        editor.playheadMs = 0
        editor.split()
        #expect(editor.problem == "studio.editor.error.split")
        #expect(edl.ops == ["append"])
        editor.playheadMs = 2_000
        editor.split()
        #expect(editor.problem == nil)
        #expect(editor.clips.map(\.timelineStartMs) == [0, 2_000])
        #expect(editor.selection == "c-3")
        #expect(edl.lastOp?["atMs"] as? Int == 2_000)
        editor.undo()
        #expect(editor.clips.count == 1)
        #expect(editor.selection == nil)
    }

    @Test func aRefusedEditLeavesTheProjectAndSaysWhy() {
        let edl = FakeEDL()
        let editor = model(edl)
        editor.importClip(url: URL(fileURLWithPath: "/a.mp4"), media: media)
        let before = editor.project
        edl.refuse = ["move"]
        editor.nudge("c-2", by: 1_000)
        #expect(editor.project == before)
        #expect(editor.problem == "studio.editor.error.overlap")
        #expect(edl.lastOp?["startMs"] as? Int == 1_000)
        editor.clearProblem()
        #expect(editor.problem == nil)
    }

    @Test func joinNeedsAClipRightAfterTheSelection() {
        let edl = FakeEDL()
        let editor = model(edl)
        editor.importClip(url: URL(fileURLWithPath: "/a.mp4"), media: media)
        editor.joinWithNext()
        #expect(editor.problem == "studio.editor.error.join")
        editor.playheadMs = 3_000
        editor.split()
        editor.selection = "c-2"
        #expect(editor.nextAfterSelection?.clipID == "c-3")
        editor.joinWithNext()
        #expect(edl.lastOp?["leftId"] as? String == "c-2")
        #expect(edl.lastOp?["rightId"] as? String == "c-3")
    }

    @Test func trimToThePlayheadSendsSourceTimes() {
        let edl = FakeEDL()
        let editor = model(edl)
        editor.importClip(url: URL(fileURLWithPath: "/a.mp4"), media: media)
        editor.playheadMs = 1_500
        editor.trimSelectionToPlayhead(start: true)
        #expect(edl.lastOp?["inMs"] as? Int == 1_500)
        #expect(edl.lastOp?["outMs"] as? Int == 6_000)
        editor.trimSelectionToPlayhead(start: false)
        #expect(edl.lastOp?["outMs"] as? Int == 1_500)
        editor.playheadMs = 9_000
        editor.trimSelectionToPlayhead(start: false)
        #expect(editor.problem == "studio.editor.error.trim")
        editor.trim("c-2", inMs: -50, outMs: 99_000)
        #expect(edl.lastOp?["inMs"] as? Int == 0)
        #expect(edl.lastOp?["outMs"] as? Int == 6_000)
    }

    @Test func rippleDeleteClearsTheSelection() {
        let editor = model()
        editor.importClip(url: URL(fileURLWithPath: "/a.mp4"), media: media)
        editor.rippleDelete()
        #expect(editor.isEmpty)
        #expect(editor.selection == nil)
    }

    @Test func aFileWithoutDurationIsNotImported() {
        let edl = FakeEDL()
        let editor = model(edl)
        editor.importClip(url: URL(fileURLWithPath: "/a.txt"), media: EditorSourceMedia(durationMs: 0))
        #expect(editor.isEmpty)
        #expect(editor.problem == "studio.editor.error.import")
        #expect(edl.ops.isEmpty)
    }

    @Test func theProjectIsSavedAndReopened() {
        let url = FileManager.default.temporaryDirectory.appending(path: "editor-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = EditorProjectStore(url: url)
        let edl = FakeEDL()
        let first = model(edl, store: store)
        first.importClip(url: URL(fileURLWithPath: "/a.mp4"), media: media)
        let reopened = model(edl, store: store)
        #expect(reopened.clips.map(\.clipID) == ["c-2"])
        #expect(!reopened.canUndo)
        reopened.newProject()
        #expect(reopened.isEmpty)
        #expect(model(edl, store: store).isEmpty)
    }

    @Test func emptyProjectHasOneVideoTrack() {
        let project = EditorModel.object(EditorModel.emptyProject(now: Date(timeIntervalSince1970: 1)))
        #expect(project?["schemaVersion"] as? Int == 1)
        #expect((project?["tracks"] as? [[String: Any]])?.first?["id"] as? String == "v1")
        #expect(EditorSourceMedia.fourCC(0x6176_6331) == "avc1")
    }
}

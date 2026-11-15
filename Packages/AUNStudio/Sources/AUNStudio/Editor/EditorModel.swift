import AUNCoreBridge
import AVFoundation
import Foundation
import Observation

/// What the editor knows about an imported file, for the project's `sources`.
public struct EditorSourceMedia: Hashable, Sendable {
    public var durationMs: Int
    /// Display size (after rotation) and frame rate, when the file has video.
    public var width: Int
    public var height: Int
    public var fps: Double
    public var videoCodec: String?
    public var audioCodec: String?
    public var sampleRate: Int
    public var channels: Int

    public init(
        durationMs: Int, width: Int = 0, height: Int = 0, fps: Double = 0, videoCodec: String? = nil,
        audioCodec: String? = nil, sampleRate: Int = 48_000, channels: Int = 2
    ) {
        self.durationMs = durationMs
        self.width = width
        self.height = height
        self.fps = fps
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Reads a media file's duration, size, frame rate and codecs.
    public static func inspect(_ url: URL) async throws -> EditorSourceMedia {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        var media = EditorSourceMedia(durationMs: Int((duration.isFinite ? duration : 0) * 1000))
        if let video = try await asset.loadTracks(withMediaType: .video).first {
            let (size, transform, fps, formats) = try await video.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
            let display = size.applying(transform)
            media.width = Int(abs(display.width).rounded())
            media.height = Int(abs(display.height).rounded())
            media.fps = Double(fps > 0 ? fps : 30)
            media.videoCodec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "video"
        }
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let formats = try await audio.load(.formatDescriptions)
            let description = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            media.audioCodec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "audio"
            media.sampleRate = Int(description?.mSampleRate ?? 48_000)
            media.channels = Int(description?.mChannelsPerFrame ?? 2)
        }
        return media
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = (String(bytes: bytes, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return text.isEmpty ? "unknown" : text
    }
}

/// Saves the editor's project JSON so a relaunch reopens it.
public struct EditorProjectStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func live() -> EditorProjectStore {
        EditorProjectStore(url: URL.applicationSupportDirectory.appending(path: "Studio/Editor/project.json"))
    }

    public func load() -> String? { try? String(contentsOf: url, encoding: .utf8) }

    public func save(_ project: String) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try project.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AUNLog.studio.error("Saving the editor project failed: \(error)")
        }
    }
}

/// The editor (E19 19.5): an EDL project edited only through Core (`edl_apply_json`), so trims, cuts, ripple deletes,
/// joins, moves and titles follow the same rules in every app. Undo and redo keep whole project JSON snapshots; export renders
/// `edl_flatten_json` with AVFoundation.
@MainActor @Observable
public final class EditorModel {
    public enum ExportState: Equatable, Sendable {
        case idle
        case exporting(Double)
        case finished(URL)
        /// L10n key.
        case failed(String)
    }

    /// The only video track the editor creates; imported clips go there with their sound.
    public nonisolated static let videoTrack = "v1"
    /// How far one nudge moves a clip.
    public nonisolated static let nudgeMs = 1_000

    public private(set) var history: SnapshotHistory<String>
    public private(set) var timeline = FlattenedTimeline(durationMs: 0, tracks: [])
    /// Source id → file name, for clip labels.
    public private(set) var sourceNames: [String: String] = [:]
    /// Source id → length, so trims stay inside the file.
    public private(set) var sourceDurations: [String: Int] = [:]
    public var selection: String?
    public var playheadMs = 0
    /// L10n key of the last refused edit, cleared by the next edit.
    public private(set) var problem: String?
    public private(set) var exportState = ExportState.idle
    /// The channel's brand kit for new titles and for drawing lower thirds (shape, side, logo).
    public var brand = TitleBrand()

    let edl: any EDLEditing
    private let store: EditorProjectStore?
    private var exportTask: Task<Void, Never>?
    /// Makes clip and source ids; tests make them predictable.
    var makeID: () -> String = { String(UUID().uuidString.prefix(8)).lowercased() }

    public init(edl: any EDLEditing, store: EditorProjectStore?, now: Date = Date()) {
        self.edl = edl
        self.store = store
        // A saved project Core cannot read (damaged, or from a newer schema) is not reopened.
        let saved = store?.load().flatMap { (try? edl.flatten(project: $0)) == nil ? nil : $0 }
        history = SnapshotHistory(saved ?? Self.emptyProject(now: now), limit: 200)
        refresh()
    }

    public var project: String { history.current }

    /// The project's frame size and rate (`settings`), which titles are laid out on.
    public var frameSize: CGSize {
        let settings = Self.object(project)?["settings"] as? [String: Any]
        let width = settings?["width"] as? Int ?? 1920
        let height = settings?["height"] as? Int ?? 1080
        return CGSize(width: max(1, width), height: max(1, height))
    }

    public var frameRate: Double { (Self.object(project)?["settings"] as? [String: Any])?["fps"] as? Double ?? 30 }
    public var isEmpty: Bool { timeline.tracks.allSatisfy(\.clips.isEmpty) }
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public var clips: [FlattenedTimeline.Clip] { timeline.tracks.flatMap(\.clips) }
    public var selectedClip: FlattenedTimeline.Clip? { clips.first { $0.clipID == selection } }

    /// The clip under the playhead (strictly inside it), preferring the selected one.
    public var clipAtPlayhead: FlattenedTimeline.Clip? {
        let inside = clips.filter { playheadMs > $0.timelineStartMs && playheadMs < $0.timelineStartMs + $0.timelineDurationMs }
        return inside.first { $0.clipID == selection } ?? inside.first
    }

    /// The clip right after the selection on its track, when one starts where the selection ends.
    public var nextAfterSelection: FlattenedTimeline.Clip? {
        guard let clip = selectedClip,
            let track = timeline.tracks.first(where: { $0.clips.contains { $0.clipID == clip.clipID } })
        else { return nil }
        let end = clip.timelineStartMs + clip.timelineDurationMs
        return track.clips.first { $0.timelineStartMs == end && $0.clipID != clip.clipID }
    }

    // MARK: Edits

    /// Adds a file as a source and appends it to the end of the video track, as one undo step.
    public func importClip(url: URL, media: EditorSourceMedia) {
        guard media.durationMs > 0 else { return fail("studio.editor.error.import") }
        do {
            let sourceID = "s-\(makeID())"
            var withSource = try Self.addingSource(
                to: project, id: sourceID, path: url.path, media: media, setSize: isEmpty)
            let clipID = "c-\(makeID())"
            let op: [String: Any] = [
                "op": "append", "trackId": Self.videoTrack,
                "clip": ["id": clipID, "sourceId": sourceID, "inMs": 0, "outMs": media.durationMs],
            ]
            withSource = try edl.apply(project: withSource, op: Self.json(op))
            commit(withSource)
            selection = clipID
        } catch {
            AUNLog.studio.error("Import into the editor failed: \(error)")
            fail("studio.editor.error.import")
        }
    }

    /// Cuts the clip under the playhead in two.
    public func split() {
        guard let clip = clipAtPlayhead else { return fail("studio.editor.error.split") }
        let newID = "c-\(makeID())"
        let op: [String: Any] = ["op": "split", "clipId": clip.clipID, "atMs": playheadMs, "newId": newID]
        if apply(op, refused: "studio.editor.error.split") {
            selection = newID
        }
    }

    /// Removes the selected title, or the selected clip and closes the gap.
    /// With titles, the clip's span is cut from every track, so titles move back with their video (one across the cut
    /// is trimmed, one inside it goes with the clip), as on Desktop.
    public func rippleDelete() {
        if let title = selectedTitle { return removeTitle(title.titleID) }
        guard let clip = selectedClip else { return }
        let op: [String: Any] =
            titles.isEmpty
            ? ["op": "rippleDeleteClip", "clipId": clip.clipID]
            : [
                "op": "rippleDeleteRange", "startMs": clip.timelineStartMs,
                "endMs": clip.timelineStartMs + clip.timelineDurationMs,
            ]
        if apply(op, refused: "studio.editor.error.refused") {
            selection = nil
            playheadMs = min(playheadMs, timeline.durationMs)
        }
    }

    /// Joins the selection with the clip right after it (the two halves of a cut).
    public func joinWithNext() {
        guard let clip = selectedClip, let next = nextAfterSelection else { return fail("studio.editor.error.join") }
        apply(["op": "join", "leftId": clip.clipID, "rightId": next.clipID], refused: "studio.editor.error.join")
    }

    /// Moves a clip to start at `startMs` on its track. Landing on another clip is refused.
    public func move(_ clipID: String, toMs startMs: Int) {
        guard let track = timeline.tracks.first(where: { $0.clips.contains { $0.clipID == clipID } }) else { return }
        apply(
            ["op": "move", "clipId": clipID, "trackId": track.id, "startMs": max(0, startMs)],
            refused: "studio.editor.error.overlap")
    }

    public func nudge(_ clipID: String, by deltaMs: Int) {
        if let title = titles.first(where: { $0.titleID == clipID }) {
            return moveTitle(title.titleID, toMs: title.startMs + deltaMs)
        }
        guard let clip = clips.first(where: { $0.clipID == clipID }) else { return }
        move(clipID, toMs: clip.timelineStartMs + deltaMs)
    }

    /// Sets a clip's source range (milliseconds into its file).
    public func trim(_ clipID: String, inMs: Int, outMs: Int) {
        guard let clip = clips.first(where: { $0.clipID == clipID }) else { return }
        let limit = sourceDurations[clip.sourceID] ?? outMs
        let (start, end) = (max(0, inMs), min(limit, outMs))
        guard start < end else { return fail("studio.editor.error.refused") }
        apply(["op": "trim", "clipId": clipID, "inMs": start, "outMs": end], refused: "studio.editor.error.refused")
    }

    /// Trims the selection's start (`start == true`) or end to the playhead.
    public func trimSelectionToPlayhead(start: Bool) {
        guard let clip = selectedClip else { return }
        let end = clip.timelineStartMs + clip.timelineDurationMs
        guard playheadMs > clip.timelineStartMs, playheadMs < end else { return fail("studio.editor.error.trim") }
        let source = clip.inMs + Int((Double(playheadMs - clip.timelineStartMs) * clip.speed).rounded())
        if start {
            trim(clip.clipID, inMs: source, outMs: clip.outMs)
        } else {
            trim(clip.clipID, inMs: clip.inMs, outMs: source)
        }
    }

    public func undo() {
        guard history.undo() != nil else { return }
        afterHistoryChange()
    }

    public func redo() {
        guard history.redo() != nil else { return }
        afterHistoryChange()
    }

    /// Starts an empty project. The old one is gone (not an undo step).
    public func newProject(now: Date = Date()) {
        cancelExport()
        history.reset(Self.emptyProject(now: now))
        selection = nil
        playheadMs = 0
        problem = nil
        exportState = .idle
        refresh()
        store?.save(project)
    }

    public func clearProblem() { problem = nil }

    // MARK: Export

    /// Renders the timeline to an MP4 at `url` (replacing it) for the normal upload.
    public func export(to url: URL) {
        guard !isEmpty else { return }
        cancelExport()
        let timeline = timeline
        let (brand, fps) = (brand, frameRate)
        exportState = .exporting(0)
        exportTask = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await TimelineComposer.export(timeline, to: url, brand: brand, fps: fps) { fraction in
                    Task { @MainActor in
                        if case .exporting = self?.exportState { self?.exportState = .exporting(fraction) }
                    }
                }
                self?.exportState = .finished(url)
            } catch is CancellationError {
                self?.exportState = .idle
            } catch {
                AUNLog.studio.error("Editor export failed: \(error)")
                self?.exportState = .failed("studio.editor.error.export")
            }
        }
    }

    public func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        if case .exporting = exportState { exportState = .idle }
    }

    /// Where exports go by default: the folder the encode queue also uses.
    public static func defaultExportURL(now: Date = Date()) -> URL {
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        return URL.moviesDirectory.appending(path: "Al Ummah Now Studio/Edit \(stamp).mp4")
    }

    // MARK: Internals

    /// Sends one op through Core. On refusal the project stays as it was and `refused` is shown.
    @discardableResult
    func apply(_ op: [String: Any], refused: String) -> Bool {
        do {
            commit(try edl.apply(project: project, op: Self.json(op)))
            return true
        } catch {
            AUNLog.studio.info("Edit refused: \(error)")
            fail(refused)
            return false
        }
    }

    func commit(_ next: String) {
        history.record(next)
        problem = nil
        refresh()
        store?.save(project)
    }

    private func afterHistoryChange() {
        problem = nil
        refresh()
        if let selection, !clips.contains(where: { $0.clipID == selection }),
            !titles.contains(where: { $0.titleID == selection })
        {
            self.selection = nil
        }
        playheadMs = min(playheadMs, timeline.durationMs)
        store?.save(project)
    }

    func fail(_ key: String) { problem = key }

    private func refresh() {
        timeline = (try? edl.flatten(project: project)) ?? FlattenedTimeline(durationMs: 0, tracks: [])
        let sources = (Self.object(project)?["sources"] as? [[String: Any]]) ?? []
        sourceNames = Dictionary(
            sources.compactMap { source in
                guard let id = source["id"] as? String, let path = source["path"] as? String else { return nil }
                return (id, URL(fileURLWithPath: path).lastPathComponent)
            }, uniquingKeysWith: { first, _ in first })
        sourceDurations = Dictionary(
            sources.compactMap { source in
                guard let id = source["id"] as? String, let ms = source["durationMs"] as? Int else { return nil }
                return (id, ms)
            }, uniquingKeysWith: { first, _ in first })
    }

    nonisolated static func json(_ object: [String: Any]) throws -> String {
        String(bytes: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
    }

    nonisolated static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// A new project (EDL schema 1) with one empty video track.
    nonisolated static func emptyProject(now: Date) -> String {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let project: [String: Any] = [
            "schemaVersion": 1, "id": UUID().uuidString.lowercased(),
            "metadata": ["title": "", "createdAtMs": ms, "updatedAtMs": ms],
            "settings": ["width": 1920, "height": 1080, "fps": 30.0, "sampleRate": 48_000, "channels": 2],
            "sources": [], "tracks": [["id": videoTrack, "kind": "video"]],
        ]
        return (try? json(project)) ?? "{}"
    }

    /// Adds a source to the project JSON (Core has no op for sources). The first video also sets the project size.
    nonisolated static func addingSource(
        to project: String, id: String, path: String, media: EditorSourceMedia, setSize: Bool
    ) throws -> String {
        guard var object = object(project) else { throw CoreError.decoding }
        var source: [String: Any] = ["id": id, "path": path, "durationMs": media.durationMs]
        if let codec = media.videoCodec {
            source["video"] = ["codec": codec, "width": media.width, "height": media.height, "fps": media.fps]
            if setSize, media.width > 0, media.height > 0, var settings = object["settings"] as? [String: Any] {
                settings["width"] = media.width
                settings["height"] = media.height
                settings["fps"] = media.fps
                object["settings"] = settings
            }
        }
        if let codec = media.audioCodec {
            source["audio"] = ["codec": codec, "sampleRate": media.sampleRate, "channels": media.channels]
        }
        object["sources"] = ((object["sources"] as? [[String: Any]]) ?? []) + [source]
        if var metadata = object["metadata"] as? [String: Any] {
            metadata["updatedAtMs"] = Int(Date().timeIntervalSince1970 * 1000)
            object["metadata"] = metadata
        }
        return try json(object)
    }
}

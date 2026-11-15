import AUNCoreBridge
import AunCore
import Foundation

// Core's media engines (aun-media through AunCore) behind the bridge protocols. Swift task cancellation becomes
// `MediaCancel`, Core progress callbacks become plain closures, and `AunError` becomes `CoreError`.

/// Relays Core's `done`/`total` callbacks as a 0…1 fraction.
final class ProgressRelay: MediaProgress, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func onProgress(done: UInt64, total: UInt64) {
        guard total > 0 else { return }
        report(min(1, Double(done) / Double(total)))
    }
}

/// Runs an async Core call with a `MediaCancel` that the surrounding task's cancellation trips.
func withMediaCancel<T: Sendable>(_ body: (MediaCancel) async throws -> T) async throws -> T {
    let cancel = MediaCancel()
    do {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await body(cancel)
        } onCancel: {
            cancel.cancel()
        }
    } catch let error as AunError {
        throw CoreError(media: error)
    }
}

func mapMedia<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let error as AunError { throw CoreError(media: error) }
}

extension CoreError {
    /// Media errors keep Core's detail for the log: a refused edit is `invalid`, a locked track a `conflict`.
    init(media error: AunError) {
        switch error {
        case .InvalidInput(let detail): self = .invalid(detail)
        case .Conflict(let detail): self = .conflict(detail)
        case .NotFound: self = .notFound
        case .Cancelled: self = .cancelled
        case .Unsupported(let detail), .Storage(let detail), .Platform(let detail), .Internal(let detail):
            self = .upload(detail)
        default: self = CoreError(error)
        }
    }
}

/// `hls_ladder`, `hls_package_mp4` and `renditions_files` (D11).
public struct CoreRenditionPackaging: RenditionPackaging {
    public init() {}

    public func ladder(width: Int, height: Int, rotation: Int) -> [HLSRung] {
        guard width > 0, height > 0 else { return [] }
        do {
            return try hlsLadder(width: UInt32(width), height: UInt32(height), rotation: Int32(rotation)).map(HLSRung.init)
        } catch {
            AUNLog.studio.error("hls_ladder failed: \(error)")
            return []
        }
    }

    public func package(mp4: URL, outputDirectory: URL, segmentSeconds: Double) async throws -> HLSPackage {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let package = try await withMediaCancel { cancel in
            try await hlsPackageMp4(
                inputMp4: mp4.path, outDir: outputDirectory.path, segmentSeconds: UInt32(max(1, segmentSeconds.rounded())),
                cancel: cancel)
        }
        return HLSPackage(
            files: package.files.map { AUNCoreBridge.StagedFile(path: $0.path, bytes: Int64($0.bytes)) },
            durationMs: Int(package.durationMs))
    }

    public func files(root: URL, rungs: [String]) throws -> [AUNCoreBridge.StagedFile] {
        try mapMedia { try renditionsFiles(rootDir: root.path, rungs: rungs) }.map {
            AUNCoreBridge.StagedFile(path: $0.path, bytes: Int64($0.bytes))
        }
    }
}

extension HLSRung {
    init(_ rung: HlsRung) {
        self.init(
            name: rung.name, width: Int(rung.width), height: Int(rung.height), maxrate: Int(rung.maxrate),
            bufsize: Int(rung.bufsize), audioBitrate: Int(rung.audioBitrate), profile: rung.profile,
            gopSeconds: Double(rung.gopSeconds), segmentSeconds: Double(rung.segmentSeconds), maxFPS: rung.maxFps)
    }
}

/// `edl_apply_json` and `edl_flatten_json`: every editor edit goes through Core.
public struct CoreEDLEditing: EDLEditing {
    public init() {}

    public func apply(project: String, op: String) throws -> String {
        try mapMedia { try edlApplyJson(projectJson: project, opJson: op) }
    }

    public func flatten(project: String) throws -> FlattenedTimeline {
        try FlattenedTimeline.decode(mapMedia { try edlFlattenJson(projectJson: project) })
    }

    /// Migrates a saved project to the current schema (and checks it parses).
    public func load(project: String) throws -> String {
        try mapMedia { try edlLoadProject(json: project) }
    }
}

/// Core's whisper.cpp with its model store (D10). Only the macOS slice of Core has whisper.
public final class CoreOnDeviceTranscriber: OnDeviceTranscribing, @unchecked Sendable {
    private let store: ModelStore
    /// Lines per cue are at most this long (two lines per cue), like the server's captions.
    let maxLineChars: UInt32

    public init(directory: URL = CoreOnDeviceTranscriber.defaultDirectory, maxLineChars: UInt32 = 42) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ModelStore(dir: directory.path)
        self.maxLineChars = maxLineChars
    }

    /// Models live in Application Support, so they survive app updates and are not backed up as documents.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Studio/Models", directoryHint: .isDirectory)
    }

    public var isAvailable: Bool { transcriptionOnDeviceAvailable() }

    public func models() throws -> [TranscriptionModel] {
        try mapMedia { try store.list() }.map {
            TranscriptionModel(id: $0.model.id, installed: $0.installed, sizeBytes: Int64($0.model.sizeBytes))
        }
    }

    public func download(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let relay = ProgressRelay(progress)
        _ = try await withMediaCancel { cancel in try await store.download(id: model, progress: relay, cancel: cancel) }
    }

    public func deleteModel(_ id: String) throws { try mapMedia { try store.delete(id: id) } }

    public func transcribe(
        model: String, media: URL, language: String?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        guard let path = try mapMedia({ try store.path(id: model) }) else { throw CoreError.notFound }
        let relay = ProgressRelay(progress)
        let transcript = try await withMediaCancel { cancel in
            try await transcribeOnDeviceJson(
                modelPath: path, mediaPath: media.path, language: language, progress: relay, cancel: cancel)
        }
        let segments = try mapMedia {
            try transcriptToCaptionSegmentsJson(transcriptJson: transcript, maxLineChars: maxLineChars)
        }
        return try Self.decodeSegments(segments)
    }

    static func decodeSegments(_ json: String) throws -> [TranscriptSegment] {
        do {
            return try JSONDecoder().decode([TranscriptSegment].self, from: Data(json.utf8))
        } catch {
            throw CoreError.decoding
        }
    }
}

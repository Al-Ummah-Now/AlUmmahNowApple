import Foundation

// The aun-media calls desktop Studio needs (Core `hls_ladder`, `hls_package_mp4`, `edl_apply_json`, `edl_flatten_json`,
// `ModelStore`, `transcribe_on_device_json`). AUNCoreKit adapts Core to these protocols; features only see these.
// Cancellation is Swift task cancellation; adapters turn it into Core's `MediaCancel`.

/// One rung of the server's HLS ladder (`HlsRung`), the same one apps/media encodes.
public struct HLSRung: Hashable, Sendable, Codable, Identifiable {
    public var name: String
    public var width: Int
    public var height: Int
    /// Bits per second.
    public var maxrate: Int
    public var bufsize: Int
    public var audioBitrate: Int
    /// `high` or `main`.
    public var profile: String
    public var gopSeconds: Double
    public var segmentSeconds: Double
    public var maxFPS: Double
    public var id: String { name }

    public init(
        name: String, width: Int, height: Int, maxrate: Int, bufsize: Int, audioBitrate: Int, profile: String,
        gopSeconds: Double = 2, segmentSeconds: Double = 6, maxFPS: Double = 30
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.maxrate = maxrate
        self.bufsize = bufsize
        self.audioBitrate = audioBitrate
        self.profile = profile
        self.gopSeconds = gopSeconds
        self.segmentSeconds = segmentSeconds
        self.maxFPS = maxFPS
    }

    /// The encoder's average target: under the peak so the peak stays under `maxrate`.
    public var averageBitRate: Int { Int(Double(maxrate) * 0.8) }

    /// Frames per second for a source: capped at `maxFPS` only when the source is above 31.
    public func outputFPS(source: Double) -> Double { source > 31 ? min(source, maxFPS) : source }
}

/// The fMP4 HLS files written for one rung (`HlsPackage`).
public struct HLSPackage: Hashable, Sendable {
    public var files: [StagedFile]
    public var durationMs: Int

    public init(files: [StagedFile], durationMs: Int) {
        self.files = files
        self.durationMs = durationMs
    }
}

/// Ladder and packaging for pre-encoded renditions (D11).
public protocol RenditionPackaging: Sendable {
    func ladder(width: Int, height: Int, rotation: Int) -> [HLSRung]
    /// Writes `init.mp4`, `seg_00001.m4s`… and `index.m3u8` for a progressive MP4 into `outputDirectory`.
    func package(mp4: URL, outputDirectory: URL, segmentSeconds: Double) async throws -> HLSPackage
    /// The file list for `POST /renditions` (`<rung>/<file>`), from the rung folders under `root`.
    func files(root: URL, rungs: [String]) throws -> [StagedFile]
}

/// The edit list engine. Every edit goes through Core, so timeline rules match every app.
public protocol EDLEditing: Sendable {
    /// Applies one edit (`op` is the tagged JSON object). Errors leave the project unchanged.
    func apply(project: String, op: String) throws -> String
    func flatten(project: String) throws -> FlattenedTimeline
}

/// `edl_flatten_json`: clips in timeline order, ready for a composition.
public struct FlattenedTimeline: Hashable, Sendable, Decodable {
    public struct Clip: Hashable, Sendable, Decodable {
        public var clipID: String
        public var sourceID: String
        public var path: String
        public var inMs: Int
        public var outMs: Int
        public var timelineStartMs: Int
        public var speed: Double
        public var volume: Double

        public init(
            clipID: String, sourceID: String, path: String, inMs: Int, outMs: Int, timelineStartMs: Int, speed: Double = 1,
            volume: Double = 1
        ) {
            self.clipID = clipID
            self.sourceID = sourceID
            self.path = path
            self.inMs = inMs
            self.outMs = outMs
            self.timelineStartMs = timelineStartMs
            self.speed = speed
            self.volume = volume
        }

        enum CodingKeys: String, CodingKey {
            case clipID = "clipId"
            case sourceID = "sourceId"
            case path, inMs, outMs, timelineStartMs, speed, volume
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clipID = try c.decode(String.self, forKey: .clipID)
            sourceID = try c.decode(String.self, forKey: .sourceID)
            path = try c.decode(String.self, forKey: .path)
            inMs = try c.decode(Int.self, forKey: .inMs)
            outMs = try c.decode(Int.self, forKey: .outMs)
            timelineStartMs = try c.decode(Int.self, forKey: .timelineStartMs)
            speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
            volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        }

        /// Time on the timeline: the source span divided by the speed.
        public var timelineDurationMs: Int { Int((Double(outMs - inMs) / max(speed, 0.01)).rounded()) }
    }

    public struct Track: Hashable, Sendable, Decodable, Identifiable {
        public var id: String
        /// `video` or `audio`.
        public var kind: String
        public var muted: Bool
        public var clips: [Clip]

        public init(id: String, kind: String, muted: Bool = false, clips: [Clip]) {
            self.id = id
            self.kind = kind
            self.muted = muted
            self.clips = clips
        }

        enum CodingKeys: String, CodingKey { case id, kind, muted, clips }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(String.self, forKey: .kind)
            muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
            clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        }
    }

    public var durationMs: Int
    public var tracks: [Track]

    public init(durationMs: Int, tracks: [Track]) {
        self.durationMs = durationMs
        self.tracks = tracks
    }

    public static func decode(_ json: String) throws -> FlattenedTimeline {
        do {
            return try JSONDecoder().decode(FlattenedTimeline.self, from: Data(json.utf8))
        } catch {
            throw CoreError.decoding
        }
    }
}

/// A whisper model on this computer (`ModelStatus`).
public struct TranscriptionModel: Identifiable, Hashable, Sendable {
    public var id: String
    public var installed: Bool
    public var sizeBytes: Int64

    public init(id: String, installed: Bool, sizeBytes: Int64) {
        self.id = id
        self.installed = installed
        self.sizeBytes = sizeBytes
    }
}

/// Free transcription on this computer (D10, Core's whisper.cpp).
public protocol OnDeviceTranscribing: Sendable {
    /// False in builds without whisper; Studio then offers only server transcription.
    var isAvailable: Bool { get }
    func models() throws -> [TranscriptionModel]
    /// `progress` gets 0…1.
    func download(model: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func deleteModel(_ id: String) throws
    /// Timed segments in the shape of the on-device transcript body. `progress` gets 0…1.
    func transcribe(
        model: String, media: URL, language: String?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment]
}

/// A transcriber for UI tests and previews: a fixed transcript after a short pretend run. Never used live.
public struct FixtureTranscriber: OnDeviceTranscribing {
    public init() {}
    public var isAvailable: Bool { true }
    public func models() throws -> [TranscriptionModel] {
        [
            TranscriptionModel(id: "base-q5_1", installed: true, sizeBytes: 59_700_000),
            TranscriptionModel(id: "large-v3-turbo-q5_0", installed: false, sizeBytes: 574_000_000),
        ]
    }
    public func download(model: String, progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }
    public func deleteModel(_ id: String) throws {}
    public func transcribe(
        model: String, media: URL, language: String?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        progress(1)
        return [TranscriptSegment(startMs: 0, endMs: 2_000, text: "بسم الله")]
    }
}

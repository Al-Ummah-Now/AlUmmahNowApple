import Foundation

/// Where a caption draft came from (`origin` in the drafts API).
public enum CaptionOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case reviewTranscript = "review_transcript"
    case transcription
    case translation
    case onDevice = "on_device"
}

/// A draft in the list (`GET /api/videos/:id/captions/drafts`).
public struct CaptionDraftSummary: Identifiable, Hashable, Sendable, Decodable {
    public enum Track: String, Sendable, Hashable, Decodable { case none, machine, upload }

    public var language: String
    public var version: Int
    public var origin: CaptionOrigin?
    public var edited: Bool
    public var cueCount: Int
    /// Quran suggestions the creator has not accepted yet.
    public var pendingQuran: Int
    public var updatedAt: Date?
    public var publishedVersion: Int?
    public var publishedAt: Date?
    public var track: Track
    public var id: String { language }

    public init(
        language: String, version: Int, origin: CaptionOrigin?, edited: Bool = false, cueCount: Int, pendingQuran: Int = 0,
        updatedAt: Date? = nil, publishedVersion: Int? = nil, publishedAt: Date? = nil, track: Track = .none
    ) {
        self.language = language
        self.version = version
        self.origin = origin
        self.edited = edited
        self.cueCount = cueCount
        self.pendingQuran = pendingQuran
        self.updatedAt = updatedAt
        self.publishedVersion = publishedVersion
        self.publishedAt = publishedAt
        self.track = track
    }

    enum CodingKeys: String, CodingKey {
        case language, version, origin, edited, cues, cueCount, pendingQuran, updatedAt, publishedVersion, publishedAt, track
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decode(String.self, forKey: .language)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        origin = try? c.decodeIfPresent(CaptionOrigin.self, forKey: .origin)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        // The list sends `cues` as a count; one draft sends the cue array and `cueCount`.
        cueCount = (try? c.decodeIfPresent(Int.self, forKey: .cueCount)) ?? (try? c.decodeIfPresent(Int.self, forKey: .cues)) ?? 0
        pendingQuran = try c.decodeIfPresent(Int.self, forKey: .pendingQuran) ?? 0
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        publishedVersion = try c.decodeIfPresent(Int.self, forKey: .publishedVersion)
        publishedAt = try? c.decodeIfPresent(Date.self, forKey: .publishedAt)
        track = (try? c.decodeIfPresent(Track.self, forKey: .track)) ?? .none
    }

    /// Published, and not edited since.
    public var isPublished: Bool { publishedVersion != nil }
    public var isOutdated: Bool { publishedVersion.map { $0 != version } ?? false }
}

/// A review-transcript or on-device claim still being turned into a draft, or one that failed.
public struct CaptionClaim: Hashable, Sendable, Decodable {
    public enum Status: String, Sendable, Decodable { case queued, failed }
    public var language: String
    public var status: Status
    public var error: String?

    public init(language: String, status: Status, error: String? = nil) {
        self.language = language
        self.status = status
        self.error = error
    }
}

public struct CaptionDraftList: Hashable, Sendable, Decodable {
    public var drafts: [CaptionDraftSummary]
    public var claims: [CaptionClaim]
    public var transcriptAvailable: Bool

    public init(drafts: [CaptionDraftSummary], claims: [CaptionClaim] = [], transcriptAvailable: Bool = false) {
        self.drafts = drafts
        self.claims = claims
        self.transcriptAvailable = transcriptAvailable
    }

    enum CodingKeys: String, CodingKey { case drafts, claims, transcriptAvailable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drafts = try c.decodeIfPresent([CaptionDraftSummary].self, forKey: .drafts) ?? []
        claims = (try? c.decodeIfPresent([CaptionClaim].self, forKey: .claims)) ?? []
        transcriptAvailable = try c.decodeIfPresent(Bool.self, forKey: .transcriptAvailable) ?? false
    }
}

/// A Quran reference inside a cue. Studio keeps every field it does not edit exactly as the server sent it.
public struct CaptionQuranSegment: Hashable, Sendable, Codable {
    public var range: String
    public var status: String
    public var alternatives: [String]?
    public var heard: String?

    public init(range: String, status: String, alternatives: [String]? = nil, heard: String? = nil) {
        self.range = range
        self.status = status
        self.alternatives = alternatives
        self.heard = heard
    }
}

public enum CaptionSegment: Hashable, Sendable, Codable {
    case speech(String)
    case quran(CaptionQuranSegment)

    enum CodingKeys: String, CodingKey { case type, text }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "speech": self = .speech(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "quran": self = .quran(try CaptionQuranSegment(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown segment")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .speech(let text):
            try c.encode("speech", forKey: .type)
            try c.encode(text, forKey: .text)
        case .quran(let quran):
            try c.encode("quran", forKey: .type)
            try quran.encode(to: encoder)
        }
    }

    public var speech: String? {
        if case .speech(let text) = self { return text }
        return nil
    }
}

/// One caption line with its time on the video.
public struct CaptionCue: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var startMs: Int
    public var endMs: Int
    public var segments: [CaptionSegment]

    public init(id: String, startMs: Int, endMs: Int, segments: [CaptionSegment]) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.segments = segments
    }

    /// The cue's speech, for search and accessible names. Quran references are not text.
    public var speechText: String { segments.compactMap(\.speech).joined(separator: " ") }
    public var hasQuran: Bool { segments.contains { if case .quran = $0 { true } else { false } } }
}

/// One draft with its cues (`GET …/captions/drafts/:language`).
public struct CaptionDraft: Hashable, Sendable, Decodable {
    public var summary: CaptionDraftSummary
    public var cues: [CaptionCue]

    public init(summary: CaptionDraftSummary, cues: [CaptionCue]) {
        self.summary = summary
        self.cues = cues
    }

    enum CodingKeys: String, CodingKey { case cues }

    public init(from decoder: any Decoder) throws {
        summary = try CaptionDraftSummary(from: decoder)
        cues = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([CaptionCue].self, forKey: .cues) ?? []
    }
}

/// A server transcription (`POST|GET …/captions/jobs`).
public struct CaptionJob: Identifiable, Hashable, Sendable, Decodable {
    public enum Status: String, Sendable, Decodable {
        case queued, waitingBudget = "waiting_budget", extracting, transcribing, postprocessing, ready, failed, cancelled
    }
    public struct Progress: Hashable, Sendable, Decodable {
        public var done: Int
        public var total: Int
    }

    public var id: String
    public var language: String
    public var status: Status
    public var progress: Progress?
    public var minutesReserved: Double
    public var minutesCharged: Double?
    public var error: String?
    public var createdAt: Date?

    public init(
        id: String, language: String, status: Status, progress: Progress? = nil, minutesReserved: Double = 0,
        minutesCharged: Double? = nil, error: String? = nil, createdAt: Date? = nil
    ) {
        self.id = id
        self.language = language
        self.status = status
        self.progress = progress
        self.minutesReserved = minutesReserved
        self.minutesCharged = minutesCharged
        self.error = error
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, language, status, progress, minutesReserved, minutesCharged, error, createdAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        language = try c.decode(String.self, forKey: .language)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .failed
        progress = try? c.decodeIfPresent(Progress.self, forKey: .progress)
        minutesReserved = try c.decodeIfPresent(Double.self, forKey: .minutesReserved) ?? 0
        minutesCharged = try c.decodeIfPresent(Double.self, forKey: .minutesCharged)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public var isActive: Bool { ![.ready, .failed, .cancelled].contains(status) }
}

/// Caption minutes for transcribing one video (`GET …/captions/minutes`).
public struct CaptionMinutes: Hashable, Sendable, Decodable {
    public var unlimited: Bool
    /// `tier`, `super_admin` or `none` (the plan has no minutes).
    public var via: String
    public var monthLimit: Double?
    public var monthUsed: Double
    public var remaining: Double?
    public var overdraft: Double
    public var packsRemaining: Double
    public var held: Double
    public var warning: Bool
    public var resetsAt: Date?
    /// What transcribing this video costs; nil while its length is unknown.
    public var minutesNeeded: Double?

    public init(
        unlimited: Bool = false, via: String = "tier", monthLimit: Double? = nil, monthUsed: Double = 0,
        remaining: Double? = nil, overdraft: Double = 0, packsRemaining: Double = 0, held: Double = 0, warning: Bool = false,
        resetsAt: Date? = nil, minutesNeeded: Double? = nil
    ) {
        self.unlimited = unlimited
        self.via = via
        self.monthLimit = monthLimit
        self.monthUsed = monthUsed
        self.remaining = remaining
        self.overdraft = overdraft
        self.packsRemaining = packsRemaining
        self.held = held
        self.warning = warning
        self.resetsAt = resetsAt
        self.minutesNeeded = minutesNeeded
    }

    enum Outer: String, CodingKey { case usage, minutesNeeded }
    enum CodingKeys: String, CodingKey {
        case unlimited, via, monthLimit, monthUsed, remaining, overdraft, packsRemaining, held, warning, resetsAt
    }

    public init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let c = try outer.nestedContainer(keyedBy: CodingKeys.self, forKey: .usage)
        unlimited = try c.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
        via = try c.decodeIfPresent(String.self, forKey: .via) ?? "none"
        monthLimit = try c.decodeIfPresent(Double.self, forKey: .monthLimit)
        monthUsed = try c.decodeIfPresent(Double.self, forKey: .monthUsed) ?? 0
        remaining = try c.decodeIfPresent(Double.self, forKey: .remaining)
        overdraft = try c.decodeIfPresent(Double.self, forKey: .overdraft) ?? 0
        packsRemaining = try c.decodeIfPresent(Double.self, forKey: .packsRemaining) ?? 0
        held = try c.decodeIfPresent(Double.self, forKey: .held) ?? 0
        warning = try c.decodeIfPresent(Bool.self, forKey: .warning) ?? false
        resetsAt = try? c.decodeIfPresent(Date.self, forKey: .resetsAt)
        minutesNeeded = try outer.decodeIfPresent(Double.self, forKey: .minutesNeeded)
    }

    /// The plan includes no caption minutes.
    public var hasNoPlan: Bool { via == "none" && !unlimited }
    /// A new job may start while the balance is above 0.
    public var canStart: Bool { unlimited || (remaining ?? 0) > 0 }
}

/// One timed line of an on-device transcript, the body of `POST …/drafts/:language/transcript`.
public struct TranscriptSegment: Hashable, Sendable, Codable {
    public var startMs: Int
    public var endMs: Int
    public var text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// The engine an on-device transcript came from (`engine` in the request).
public struct TranscriptEngine: Hashable, Sendable, Codable {
    public var provider: String
    public var model: String?

    public init(provider: String = "whisper.cpp", model: String?) {
        self.provider = provider
        self.model = model
    }
}

/// The body of `POST …/drafts/:language/transcript`.
public struct OnDeviceTranscript: Hashable, Sendable, Encodable {
    public var segments: [TranscriptSegment]
    public var engine: TranscriptEngine
    /// Replaces an existing draft of the language; send it only after asking.
    public var replace: Bool

    public init(segments: [TranscriptSegment], engine: TranscriptEngine, replace: Bool = false) {
        self.segments = segments
        self.engine = engine
        self.replace = replace
    }
}

/// Cue edits that keep a draft valid for `validateCaptionCues` (ids unique, end after start, at most 10 minutes).
public enum CueEditing {
    /// The smallest cue the editor makes, and the step of the nudge buttons.
    public static let minimumMs = 100
    public static let nudgeMs = 100
    public static let maximumMs = 10 * 60 * 1000

    /// A new id that no cue in `cues` uses (`[A-Za-z0-9_-]{1,40}`).
    public static func freshID(in cues: [CaptionCue]) -> String {
        let used = Set(cues.map(\.id))
        var n = cues.count + 1
        while used.contains("e\(n)") { n += 1 }
        return "e\(n)"
    }

    /// Replaces the text of the speech segment at `segment`. An emptied cue keeps an empty speech segment until saved.
    public static func setText(_ text: String, cue index: Int, segment: Int, in cues: inout [CaptionCue]) {
        guard cues.indices.contains(index), cues[index].segments.indices.contains(segment),
            cues[index].segments[segment].speech != nil
        else { return }
        cues[index].segments[segment] = .speech(text)
    }

    /// Splits a cue at a character offset in one of its speech segments. Time is shared by the characters on each side.
    /// Returns false (and changes nothing) when either side would be shorter than `minimumMs` or have no content.
    @discardableResult
    public static func split(cue index: Int, segment: Int, at offset: Int, in cues: inout [CaptionCue]) -> Bool {
        guard cues.indices.contains(index) else { return false }
        let cue = cues[index]
        guard cue.segments.indices.contains(segment), let text = cue.segments[segment].speech,
            (0...text.count).contains(offset)
        else { return false }
        let head = String(text.prefix(offset)).trimmingCharacters(in: .whitespaces)
        let tail = String(text.dropFirst(offset)).trimmingCharacters(in: .whitespaces)
        var first = Array(cue.segments[..<segment])
        if !head.isEmpty { first.append(.speech(head)) }
        var second: [CaptionSegment] = tail.isEmpty ? [] : [.speech(tail)]
        second += cue.segments[(segment + 1)...]
        guard !first.isEmpty, !second.isEmpty else { return false }
        let weight = { (segments: [CaptionSegment]) in
            segments.reduce(0) { $0 + max(1, ($1.speech ?? "").count) }
        }
        let share = Double(weight(first)) / Double(weight(first) + weight(second))
        let at = cue.startMs + Int((Double(cue.endMs - cue.startMs) * share).rounded())
        guard at - cue.startMs >= minimumMs, cue.endMs - at >= minimumMs else { return false }
        cues[index].endMs = at
        cues[index].segments = first
        cues.insert(CaptionCue(id: freshID(in: cues), startMs: at, endMs: cue.endMs, segments: second), at: index + 1)
        return true
    }

    /// Joins a cue with the next one. Neighbouring speech is joined with a space. False when the result would be longer
    /// than the server's 10 minutes or the segment limit.
    @discardableResult
    public static func mergeWithNext(cue index: Int, in cues: inout [CaptionCue]) -> Bool {
        guard cues.indices.contains(index), cues.indices.contains(index + 1) else { return false }
        let next = cues[index + 1]
        var segments = cues[index].segments
        for segment in next.segments {
            if let text = segment.speech, let last = segments.last?.speech {
                segments[segments.count - 1] = .speech([last, text].filter { !$0.isEmpty }.joined(separator: " "))
            } else {
                segments.append(segment)
            }
        }
        let end = max(cues[index].endMs, next.endMs)
        guard end - cues[index].startMs <= maximumMs, segments.count <= 24 else { return false }
        cues[index].segments = segments
        cues[index].endMs = end
        cues.remove(at: index + 1)
        return true
    }

    public enum Edge: Sendable { case start, end }

    /// Moves a cue's start or end by `deltaMs`, kept between its neighbours, at least `minimumMs` long and at most
    /// 10 minutes. Returns false when nothing could move.
    @discardableResult
    public static func nudge(_ edge: Edge, by deltaMs: Int, cue index: Int, in cues: inout [CaptionCue]) -> Bool {
        guard cues.indices.contains(index) else { return false }
        var cue = cues[index]
        switch edge {
        case .start:
            let floor = max(0, index > 0 ? cues[index - 1].endMs : 0, cue.endMs - maximumMs)
            cue.startMs = min(max(floor, cue.startMs + deltaMs), cue.endMs - minimumMs)
        case .end:
            let ceiling = min(index + 1 < cues.count ? cues[index + 1].startMs : Int.max, cue.startMs + maximumMs)
            cue.endMs = max(min(ceiling, cue.endMs + deltaMs), cue.startMs + minimumMs)
        }
        guard cue != cues[index] else { return false }
        cues[index] = cue
        return true
    }

    /// Removes a cue.
    public static func delete(cue index: Int, in cues: inout [CaptionCue]) {
        guard cues.indices.contains(index) else { return }
        cues.remove(at: index)
    }

    /// The cues as saved: empty speech segments dropped, cues with no content left out (the server refuses them).
    public static func forSaving(_ cues: [CaptionCue]) -> [CaptionCue] {
        cues.compactMap { cue in
            var cue = cue
            cue.segments = cue.segments.compactMap { segment in
                guard let text = segment.speech else { return segment }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .speech(trimmed)
            }
            return cue.segments.isEmpty ? nil : cue
        }
    }
}

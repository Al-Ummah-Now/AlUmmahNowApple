import Foundation

// The admin-api review contract (AlUmmahNow docs/specs/VIDEO-REVIEW.md §6, `apps/admin-api/src/routers/review.router.ts`).
// Rows come from the server in snake_case; fields the server adds later are optional here, so older servers decode.

/// Who is signed in to the Admin app, from admin-api `GET /api/me` (permissions per role, checked on the server).
public struct StaffProfile: Hashable, Sendable, Decodable {
    public var userID: String
    public var displayName: String?
    public var roles: [String]
    public var permissions: [String]

    enum CodingKeys: String, CodingKey {
        case userID = "userId"
        case displayName, roles, permissions
    }

    public init(userID: String, displayName: String? = nil, roles: [String], permissions: [String] = []) {
        self.userID = userID
        self.displayName = displayName
        self.roles = roles
        self.permissions = permissions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(String.self, forKey: .userID)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? []
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
    }

    /// Role names read like the server does: case, spaces and dashes do not matter.
    static func normalize(_ role: String) -> String {
        let id = role.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        return id == "superadmin" ? "super_admin" : id
    }

    private var normalizedRoles: Set<String> { Set(roles.map(Self.normalize)) }

    /// May work the review queue (`isReviewer` in shared-types roles.ts). The server checks it on every call.
    public var isReviewer: Bool {
        !normalizedRoles.isDisjoint(with: ["super_admin", "admin", "moderator", "content_reviewer", "senior_reviewer"])
    }

    /// Escalations and minor items (VR7, AD13). Admins count.
    public var isSeniorReviewer: Bool { !normalizedRoles.isDisjoint(with: ["super_admin", "admin", "senior_reviewer"]) }
}

/// The queue tabs (Action needed / History).
public enum ReviewTab: String, CaseIterable, Sendable, Hashable {
    case actionNeeded = "action_needed"
    case history
}

/// Why a video waits for a person (`VideoReviewHoldCause`).
public enum HoldCause: String, Sendable, Hashable, CaseIterable {
    case nsfw, risk, escalation, appeal, budget
    case checkFailed = "check_failed"
}

/// The reasons a reviewer may give (`REVIEW_REASON_CODES`). en/ar text: `admin.reason.<code>`.
public enum ReviewReason: String, CaseIterable, Sendable, Hashable, Identifiable {
    case sexual, hate, harassment, privacy, copyright, impersonation, other
    case childSafety = "child_safety"
    case graphicViolence = "graphic_violence"
    case selfHarm = "self_harm"
    case violentExtremism = "violent_extremism"
    case spamScam = "spam_scam"
    case misleadingMetadata = "misleading_metadata"
    case religiousMisattribution = "religious_misattribution"

    public var id: String { rawValue }
}

/// A decision a reviewer sends. `requestChanges` keeps the video private and asks the creator to edit.
public enum ReviewDecision: String, Sendable, Hashable {
    case approve, reject, escalate, undo
    case requestChanges = "request_changes"
}

/// One row of the queue (`content_reviews`), text only: no media, so it is safe to show offline.
public struct ReviewItem: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var subjectID: String
    public var status: String
    public var title: String?
    public var channelID: String?
    public var channelName: String?
    /// The channel's trust level, as admin-web shows it (`trusted`, `new`, `warned`).
    public var channelTrust: String?
    public var risk: Double?
    public var nsfw: Bool
    public var escalate: Bool
    /// "Minor present": the server only ever sends these to senior reviewers (AD13).
    public var minor: Bool
    public var holdCause: HoldCause?
    public var topCategory: String?
    public var slaDueAt: Date?
    public var createdAt: Date?
    public var assignedTo: String?
    public var assignedToName: String?
    public var decision: String?
    public var decidedAt: Date?
    public var decidedBy: String?
    public var decidedByName: String?
    public var undoUntil: Date?
    /// The item's version; decisions send it so a second reviewer gets a conflict, not a double decision.
    public var version: Int?

    enum CodingKeys: String, CodingKey {
        case id, status, title, risk, nsfw, escalate, minor, decision, version
        case subjectID = "subject_id"
        case channelID = "channel_id"
        case channelName = "channel_name"
        case channelTrust = "channel_trust"
        case holdCause = "hold_cause"
        case topCategory = "top_category"
        case slaDueAt = "sla_due_at"
        case createdAt = "created_at"
        case assignedTo = "assigned_to"
        case assignedToName = "assigned_to_name"
        case decidedAt = "decided_at"
        case decidedBy = "decided_by"
        case decidedByName = "decided_by_name"
        case undoUntil = "undo_until"
    }

    public init(
        id: String, subjectID: String, status: String = "in_review", title: String? = nil, channelID: String? = nil,
        channelName: String? = nil, channelTrust: String? = nil, risk: Double? = nil, nsfw: Bool = false,
        escalate: Bool = false, minor: Bool = false, holdCause: HoldCause? = nil, topCategory: String? = nil,
        slaDueAt: Date? = nil, createdAt: Date? = nil, version: Int? = 1
    ) {
        self.id = id
        self.subjectID = subjectID
        self.status = status
        self.title = title
        self.channelID = channelID
        self.channelName = channelName
        self.channelTrust = channelTrust
        self.risk = risk
        self.nsfw = nsfw
        self.escalate = escalate
        self.minor = minor
        self.holdCause = holdCause
        self.topCategory = topCategory
        self.slaDueAt = slaDueAt
        self.createdAt = createdAt
        self.version = version
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        subjectID = try c.decode(String.self, forKey: .subjectID)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "in_review"
        title = try c.decodeIfPresent(String.self, forKey: .title)
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
        channelName = try c.decodeIfPresent(String.self, forKey: .channelName)
        channelTrust = try c.decodeIfPresent(String.self, forKey: .channelTrust)
        risk = try c.decodeIfPresent(Double.self, forKey: .risk)
        // D1 returns booleans as 0/1.
        nsfw = Self.flag(c, .nsfw)
        escalate = Self.flag(c, .escalate)
        minor = Self.flag(c, .minor)
        holdCause = try c.decodeIfPresent(String.self, forKey: .holdCause).flatMap(HoldCause.init(rawValue:))
        topCategory = try c.decodeIfPresent(String.self, forKey: .topCategory)
        slaDueAt = try c.decodeIfPresent(Date.self, forKey: .slaDueAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        assignedTo = try c.decodeIfPresent(String.self, forKey: .assignedTo)
        assignedToName = try c.decodeIfPresent(String.self, forKey: .assignedToName)
        decision = try c.decodeIfPresent(String.self, forKey: .decision)
        decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        decidedBy = try c.decodeIfPresent(String.self, forKey: .decidedBy)
        decidedByName = try c.decodeIfPresent(String.self, forKey: .decidedByName)
        undoUntil = try c.decodeIfPresent(Date.self, forKey: .undoUntil)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
    }

    private static func flag(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool {
        if let number = try? c.decodeIfPresent(Int.self, forKey: key) { return number != 0 }
        return (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? false
    }

    /// Blurred until a per-item, audited "Show" (NSFW or minor present).
    public var isSensitive: Bool { nsfw || minor || holdCause == .nsfw }
    public var isOpen: Bool { status == "in_review" || status == "appealed" }
}

public struct ReviewPage: Sendable, Hashable {
    public var items: [ReviewItem]
    public var nextCursor: String?

    public init(items: [ReviewItem], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// One flagged observation (`content_review_findings`).
public struct ReviewFinding: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var source: String
    public var category: String
    public var score: Double
    public var atMs: Int?
    public var endMs: Int?
    /// A frame or thumbnail of the review, read through `GET /api/review/:id/media?key=` (never a stored URL).
    public var mediaKey: String?
    public var text: String?
    public var quranRef: String?
    public var model: String?
    public var rationale: String?

    enum CodingKeys: String, CodingKey {
        case id, source, category, score, text, model, rationale
        case atMs = "at_ms"
        case endMs = "end_ms"
        case mediaKey = "media_key"
        case quranRef = "quran_ref"
    }

    public init(
        id: String, source: String, category: String, score: Double, atMs: Int? = nil, mediaKey: String? = nil,
        text: String? = nil, rationale: String? = nil
    ) {
        self.id = id
        self.source = source
        self.category = category
        self.score = score
        self.atMs = atMs
        self.mediaKey = mediaKey
        self.text = text
        self.rationale = rationale
    }
}

/// A frame of the strip: flagged frames first, then the rest of the manifest in time order.
public struct ReviewFrame: Identifiable, Hashable, Sendable {
    public var key: String
    public var atMs: Int
    public var flagged: Bool
    public var category: String?
    public var id: String { key }

    public init(key: String, atMs: Int, flagged: Bool, category: String? = nil) {
        self.key = key
        self.atMs = atMs
        self.flagged = flagged
        self.category = category
    }
}

/// Earlier reviews of the same video and the channel's record.
public struct ReviewHistoryEntry: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var status: String?
    public var decision: String?
    public var reasonCode: String?
    public var decidedAt: Date?
    public var decidedByName: String?

    enum CodingKeys: String, CodingKey {
        case id, status, decision
        case reasonCode = "reason_code"
        case decidedAt = "decided_at"
        case decidedByName = "decided_by_name"
    }

    public init(id: String, status: String?, decision: String?, reasonCode: String? = nil, decidedAt: Date? = nil) {
        self.id = id
        self.status = status
        self.decision = decision
        self.reasonCode = reasonCode
        self.decidedAt = decidedAt
    }
}

public struct ReviewSubject: Hashable, Sendable, Decodable {
    public var id: String
    public var title: String
    public var description: String
    public var tags: [String]
    public var channelID: String?
    public var duration: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, description, tags, duration
        case channelID = "channelId"
    }

    public init(id: String, title: String, description: String = "", tags: [String] = [], duration: Double? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.tags = tags
        self.duration = duration
    }
}

/// A short-lived, per-reviewer stream. Kept in memory for the open item only: never stored, logged or pushed.
public struct ReviewStream: Hashable, Sendable, Decodable {
    public var url: URL
    public var expiresAt: Date?
    /// A low-resolution preview stream (blurred items before a reveal).
    public var preview: Bool

    public init(url: URL, expiresAt: Date? = nil, preview: Bool = false) {
        self.url = url
        self.expiresAt = expiresAt
        self.preview = preview
    }

    enum CodingKeys: String, CodingKey { case url, expiresAt, preview }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        preview = try c.decodeIfPresent(Bool.self, forKey: .preview) ?? false
    }
}

/// `GET /api/review/:id`.
public struct ReviewDetail: Hashable, Sendable {
    public var item: ReviewItem
    public var findings: [ReviewFinding]
    public var history: [ReviewHistoryEntry]
    public var subject: ReviewSubject?
    public var frames: [ReviewFrame]
    public var stream: ReviewStream?

    public init(
        item: ReviewItem, findings: [ReviewFinding], history: [ReviewHistoryEntry] = [], subject: ReviewSubject? = nil,
        frames: [ReviewFrame] = [], stream: ReviewStream? = nil
    ) {
        self.item = item
        self.findings = findings
        self.history = history
        self.subject = subject
        self.frames = frames
        self.stream = stream
    }

    /// Flagged frames first (highest score first), then every other frame in time order.
    public static func frames(findings: [ReviewFinding], manifest: [ReviewFrame]) -> [ReviewFrame] {
        let flagged = findings.filter { $0.mediaKey != nil && ($0.source == "frame" || $0.source == "thumbnail") }
            .sorted { $0.score > $1.score }
        var seen = Set<String>()
        var out: [ReviewFrame] = []
        for finding in flagged {
            guard let key = finding.mediaKey, seen.insert(key).inserted else { continue }
            out.append(ReviewFrame(key: key, atMs: finding.atMs ?? 0, flagged: true, category: finding.category))
        }
        for frame in manifest.sorted(by: { $0.atMs < $1.atMs }) where seen.insert(frame.key).inserted {
            out.append(ReviewFrame(key: frame.key, atMs: frame.atMs, flagged: false))
        }
        return out
    }
}

/// The result of a decision: the row as it is now.
public struct DecisionResult: Hashable, Sendable {
    public var item: ReviewItem

    public init(item: ReviewItem) { self.item = item }
}

/// Review-specific refusals the app explains in its own words.
public enum ReviewError: Error, Equatable, Sendable {
    /// Another reviewer decided first (`409`): "Already approved by Name 20 s ago".
    case alreadyDecided(decision: String?, byName: String?, at: Date?)
    /// Being reviewed by someone else.
    case claimedByOther(name: String?)
    /// The server wants a sign-in within the last 15 minutes (`step_up_required`).
    case stepUpRequired
    case undoExpired
    case notStaff
}

/// Something that happened on the device that the audit log records (AD8 capture rules).
public enum CaptureEvent: String, Sendable, Hashable {
    case screenshot
    case recordingStarted = "recording_started"
    case recordingStopped = "recording_stopped"
}

/// The review queue on admin-api. Every call acts as the signed-in reviewer; the server checks the role each time.
public protocol ReviewServicing: Sendable {
    func profile() async throws -> StaffProfile
    func queue(_ tab: ReviewTab, query: String?, cursor: String?) async throws -> ReviewPage
    func detail(_ id: String) async throws -> ReviewDetail
    /// Claims (or renews the claim on) an item for 3 minutes.
    func claim(_ id: String) async throws
    /// Audited reveal of one blurred item (`target` names what was shown: `item`, a frame key, `player`).
    func reveal(_ id: String, target: String) async throws
    func decide(
        _ id: String, _ decision: ReviewDecision, reason: ReviewReason?, note: String?, version: Int?
    ) async throws -> DecisionResult
    /// A frame or thumbnail of the review, as bytes in memory.
    func media(_ id: String, key: String) async throws -> Data
    func recordCapture(_ event: CaptureEvent, reviewID: String?, installID: String) async throws
}

/// Push registration for the Admin app (`PUT /api/v1/devices/:installId` with `app: "admin"`).
public protocol PushRegistering: Sendable {
    func register(installID: String, token: String, platform: String, locale: String, appVersion: String) async throws
    func unregister(installID: String) async throws
}

/// What the Admin app talks to. Fixtures for UI tests; admin-api and api-videos otherwise.
public struct AdminServices: Sendable {
    public var accounts: any AccountServicing
    public var review: any ReviewServicing
    public var push: any PushRegistering
    /// The auth server's native passkey endpoints, and the issuer they live on.
    public var passkeys: any PasskeyServicing
    public var authIssuer: URL

    public init(
        accounts: any AccountServicing, review: any ReviewServicing, push: any PushRegistering,
        passkeys: any PasskeyServicing = NativePasskeyService(), authIssuer: URL = AppEnvironment.qaAuthIssuer
    ) {
        self.accounts = accounts
        self.review = review
        self.push = push
        self.passkeys = passkeys
        self.authIssuer = authIssuer
    }
}

/// Review and install ids become admin-api path segments, and they arrive from deep links and push payloads: only
/// plain ids pass (no `/`, `.`, `%`, `?` or `#`), so nothing can reach another route.
public enum ReviewID {
    public static func isValid(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count)
            && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }
}

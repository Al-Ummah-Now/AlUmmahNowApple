import Foundation

/// The review queue in memory, for UI tests, previews and unit tests: no network, no real pushes, no AI.
///
/// `fx-conflict` is always decided first by "Amina" (a version conflict); `fx-minor` only exists for seniors, as on
/// the server. Decisions move items to History and can be undone while `undoUntil` has not passed.
public actor FixtureReviewService: ReviewServicing, PushRegistering {
    public enum Role: String, Sendable { case reviewer, senior, viewer }

    private var open: [ReviewItem]
    private var decided: [ReviewItem]
    private let role: Role
    private let now: @Sendable () -> Date
    public private(set) var reveals: [String] = []
    public private(set) var claims: [String] = []
    public private(set) var captures: [CaptureEvent] = []
    public private(set) var registeredInstalls: [String: String] = [:]
    public var offline = false

    public init(role: Role = .reviewer, offline: Bool = false, now: @escaping @Sendable () -> Date = Date.init) {
        self.role = role
        self.offline = offline
        self.now = now
        let start = now()
        func due(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        var items = [
            ReviewItem(
                id: "fx-nsfw", subjectID: "v-nsfw", title: "Evening market walk", channelID: "c-1",
                channelName: "Old City Walks", channelTrust: "new", risk: 0.82, nsfw: true, holdCause: .nsfw,
                topCategory: "sexual", slaDueAt: due(3)),
            ReviewItem(
                id: "fx-risk", subjectID: "v-risk", title: "Charity drive update", channelID: "c-2",
                channelName: "Hope Relief", channelTrust: "trusted", risk: 0.41, holdCause: .risk,
                topCategory: "charity_scam", slaDueAt: due(12)),
            ReviewItem(
                id: "fx-conflict", subjectID: "v-conflict", title: "Ramadan recipes", channelID: "c-3",
                channelName: "Family Kitchen", channelTrust: "trusted", risk: 0.33, holdCause: .risk,
                topCategory: "misleading_metadata", slaDueAt: due(12)),
            ReviewItem(
                id: "fx-appeal", subjectID: "v-appeal", status: "appealed", title: "Debate night", channelID: "c-4",
                channelName: "Campus Voices", channelTrust: "warned", risk: 0.55, holdCause: .appeal,
                topCategory: "harassment", slaDueAt: due(25)),
        ]
        if role == .senior {
            items.insert(
                ReviewItem(
                    id: "fx-minor", subjectID: "v-minor", title: "Swimming lesson", channelID: "c-5",
                    channelName: "Sports Club", channelTrust: "new", risk: 0.7, escalate: true, minor: true,
                    holdCause: .escalation, topCategory: "minor_present", slaDueAt: due(5)),
                at: 0)
        }
        open = items
        var earlier = ReviewItem(
            id: "fx-old", subjectID: "v-old", status: "approved", title: "Morning reminder", channelID: "c-2",
            channelName: "Hope Relief", risk: 0.2, holdCause: .risk, topCategory: "spam", slaDueAt: due(-60))
        earlier.decision = "approve"
        earlier.decidedAt = due(-50)
        earlier.decidedByName = "Fixture Reviewer"
        decided = [earlier]
    }

    public func setOffline(_ value: Bool) { offline = value }

    private func online() throws { if offline { throw CoreError.offline } }

    public func profile() async throws -> StaffProfile {
        try online()
        switch role {
        case .viewer: throw ReviewError.notStaff
        case .reviewer: return StaffProfile(userID: "fx-reviewer", displayName: "Fixture Reviewer", roles: ["content_reviewer"])
        case .senior: return StaffProfile(userID: "fx-senior", displayName: "Fixture Senior", roles: ["senior_reviewer"])
        }
    }

    public func queue(_ tab: ReviewTab, query: String?, cursor: String?) async throws -> ReviewPage {
        try online()
        let source =
            tab == .actionNeeded ? open : decided.sorted { ($0.decidedAt ?? .distantPast) > ($1.decidedAt ?? .distantPast) }
        let q = (query ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let items =
            q.isEmpty
            ? source
            : source.filter { item in
                [item.title, item.channelName, item.topCategory, item.holdCause?.rawValue].compactMap { $0 }
                    .contains { $0.lowercased().contains(q) }
            }
        return ReviewPage(items: items)
    }

    public func detail(_ id: String) async throws -> ReviewDetail {
        try online()
        guard let item = (open + decided).first(where: { $0.id == id }) else { throw CoreError.notFound }
        let findings = [
            ReviewFinding(
                id: "\(id)-f1", source: "frame", category: item.topCategory ?? "other", score: item.risk ?? 0.5,
                atMs: 42_000, mediaKey: "review/\(item.subjectID)/r1/frame-042.jpg",
                rationale: "A frame scored above the screen threshold."),
            ReviewFinding(
                id: "\(id)-f2", source: "metadata", category: "spam", score: 0.21, text: "Donate now, limited time"),
        ]
        let manifest = (0..<4).map {
            ReviewFrame(key: "review/\(item.subjectID)/r1/frame-0\($0)0.jpg", atMs: $0 * 10_000, flagged: false)
        }
        return ReviewDetail(
            item: item, findings: findings,
            history: [
                ReviewHistoryEntry(
                    id: "\(id)-h1", status: "approved", decision: "approve", decidedAt: now().addingTimeInterval(-86_400 * 7))
            ],
            subject: ReviewSubject(
                id: item.subjectID, title: item.title ?? "", description: "A short description from the creator.",
                tags: ["community"], duration: 312),
            frames: ReviewDetail.frames(findings: findings, manifest: manifest))
    }

    public func claim(_ id: String) async throws {
        try online()
        claims.append(id)
        if let index = open.firstIndex(where: { $0.id == id }) {
            open[index].assignedTo = role == .senior ? "fx-senior" : "fx-reviewer"
        }
    }

    public func reveal(_ id: String, target: String) async throws {
        try online()
        reveals.append("\(id):\(target)")
    }

    public func decide(
        _ id: String, _ decision: ReviewDecision, reason: ReviewReason?, note: String?, version: Int?
    ) async throws -> DecisionResult {
        try online()
        if decision == .undo {
            guard let index = decided.firstIndex(where: { $0.id == id }) else { throw ReviewError.undoExpired }
            guard let until = decided[index].undoUntil, until > now() else { throw ReviewError.undoExpired }
            var item = decided.remove(at: index)
            item.status = item.holdCause == .appeal ? "appealed" : "in_review"
            item.decision = nil
            item.decidedAt = nil
            item.undoUntil = nil
            item.version = (item.version ?? 1) + 1
            open.append(item)
            open.sort { ($0.slaDueAt ?? .distantFuture) < ($1.slaDueAt ?? .distantFuture) }
            return DecisionResult(item: item)
        }
        guard let index = open.firstIndex(where: { $0.id == id }) else {
            throw ReviewError.alreadyDecided(decision: nil, byName: nil, at: nil)
        }
        if id == "fx-conflict" {
            throw ReviewError.alreadyDecided(decision: "approve", byName: "Amina", at: now().addingTimeInterval(-20))
        }
        if decision == .escalate {
            open[index].escalate = true
            open[index].holdCause = .escalation
            let item = open[index]
            if role != .senior { open.remove(at: index) }
            return DecisionResult(item: item)
        }
        var item = open.remove(at: index)
        item.status = decision == .approve ? "approved" : decision == .requestChanges ? "changes_requested" : "rejected"
        item.decision = decision.rawValue
        item.decidedAt = now()
        item.decidedByName = role == .senior ? "Fixture Senior" : "Fixture Reviewer"
        item.undoUntil = now().addingTimeInterval(600)
        item.version = (item.version ?? 1) + 1
        decided.append(item)
        return DecisionResult(item: item)
    }

    /// A 2×2 grey PNG: decoded in memory like a real frame.
    static let frame = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAAAAABX3VL4AAAADklEQVR4nGNgYGBgYAAAAAUAAXpeqz8AAAAASUVORK5CYII=")!

    public func media(_ id: String, key: String) async throws -> Data {
        try online()
        return Self.frame
    }

    public func recordCapture(_ event: CaptureEvent, reviewID: String?, installID: String) async throws {
        captures.append(event)
    }

    public func register(installID: String, token: String, platform: String, locale: String, appVersion: String) async throws {
        registeredInstalls[installID] = token
    }

    public func unregister(installID: String) async throws {
        registeredInstalls[installID] = nil
    }
}

import AUNCoreBridge
import Foundation
import Observation

/// The Dashboard's sections for one channel: recent uploads with their processing status, comments awaiting review,
/// and drafts and scheduled videos. Each loads on its own and ends in content, an empty state or hidden; when every
/// section is hidden the Dashboard has nothing to show and Studio opens on Content instead.
@MainActor @Observable
final class DashboardModel {
    /// How many rows each section lists.
    static let rows = 4

    private(set) var recent: [StudioVideo] = []
    private(set) var recentPhase: LoadPhase = .idle
    private(set) var held = HeldComments(items: [], total: 0)
    private(set) var heldPhase: LoadPhase
    private(set) var isActingOnHeldComment = false
    private(set) var hiddenAuthors: Set<String> = []
    var heldMessage: (key: String, values: [String])?

    private(set) var drafts: [StudioVideo] = []
    private(set) var scheduled: [StudioVideo] = []
    private(set) var counts: ContentCounts = [:]
    private(set) var queuePhase: LoadPhase = .idle

    let accountID: String
    let channel: StudioChannel
    let services: StudioServices
    /// Told when every section turned out hidden.
    @ObservationIgnored var onHollow: (() -> Void)?
    /// Told when a section's API answered that its feature is off, so Studio reads its features again.
    @ObservationIgnored var onFeatureOff: (() -> Void)?
    /// Account-wide refusals appear in the session banner.
    @ObservationIgnored var onAccountError: ((any Error) -> Void)?

    enum CommentAction: Sendable {
        case moderate(HeldCommentModeration)
        case report(CommentReportReason, description: String?)
        case hideAuthor
    }

    init(accountID: String, channel: StudioChannel, services: StudioServices) {
        self.accountID = accountID
        self.channel = channel
        self.services = services
        // Comments are reviewed by the channel's owner, admins and moderators only.
        heldPhase = channel.can("comment.moderate") ? .idle : .hidden
    }

    /// Every section hidden: nothing left on the Dashboard.
    var isHollow: Bool { [recentPhase, heldPhase, queuePhase].allSatisfy { $0 == .hidden } }

    func load() async {
        async let recent: Void = loadRecent()
        async let held: Void = loadHeld()
        async let queue: Void = loadQueue()
        _ = await (recent, held, queue)
        if isHollow, await isActiveAccount() { onHollow?() }
    }

    /// The newest uploads still processing, failed or published, newest first.
    func loadRecent() async {
        await LoadPhase.run(from: recentPhase, set: { recentPhase = $0 }) {
            let studio = services.studio
            let id = channel.id
            async let processing = studio.content(channelID: id, query: Self.query(.processing), cursor: nil)
            async let failed = studio.content(channelID: id, query: Self.query(.failed), cursor: nil)
            async let published = studio.content(channelID: id, query: Self.query(.published), cursor: nil)
            let all = try await processing.items + failed.items + published.items
            recent = Array(all.sorted { ($0.dateCreated ?? .distantPast) > ($1.dateCreated ?? .distantPast) }.prefix(Self.rows))
            return recent.isEmpty
        }
        reportOff(recentPhase)
    }

    func loadHeld() async {
        guard await isActiveAccount(), heldPhase != .hidden, !heldPhase.isLoading, !isActingOnHeldComment else { return }
        await LoadPhase.run(from: heldPhase, set: { heldPhase = $0 }) {
            let page: HeldComments
            do {
                page = try await services.studio.heldComments(channelID: channel.id, limit: Self.rows, accountID: accountID)
            } catch {
                guard await isActiveAccount() else { throw CancellationError() }
                throw error
            }
            guard await isActiveAccount() else { throw CancellationError() }
            held = page
            return held.total == 0 && held.items.isEmpty
        }
        reportOff(heldPhase)
    }

    func actOnHeldComment(_ comment: HeldComment, action: CommentAction) async {
        guard await isActiveAccount(), heldPhase == .ready, !isActingOnHeldComment, held.items.contains(comment) else { return }
        isActingOnHeldComment = true
        heldMessage = nil
        let previous = held
        do {
            let message: String
            var authorToHide: String?
            switch action {
            case .moderate(let moderation):
                if comment.isHeldByModeration { throw CoreError.conflict("held_by_moderation") }
                guard comment.canModerate else { throw CoreError.notFound }
                held.items.removeAll { $0.id == comment.id }
                held.total = max(held.items.count, held.total - 1)
                try await services.studio.moderateHeldComment(
                    comment, action: moderation, channelID: channel.id, accountID: accountID)
                message = moderation == .approve ? "studio.held.approved" : "studio.held.removed"
            case .report(let reason, let description):
                try await services.studio.reportHeldComment(
                    id: comment.id, reason: reason, description: description, accountID: accountID)
                message = "studio.held.reported"
            case .hideAuthor:
                guard let userID = comment.authorUserID else { throw CoreError.notFound }
                try await services.studio.hideCommentAuthor(userID: userID, channelID: channel.id, accountID: accountID)
                authorToHide = userID
                message = "studio.held.authorHidden"
            }
            guard await isActiveAccount() else { throw CancellationError() }
            if let authorToHide { hiddenAuthors.insert(authorToHide) }
            heldPhase = .loaded(isEmpty: held.total == 0 && held.items.isEmpty)
            heldMessage = (message, [])
        } catch {
            held = previous
            await handleHeldWriteError(error, action: action)
            isActingOnHeldComment = false
            return
        }
        isActingOnHeldComment = false
        // Bring the next held comment into view when this page had more waiting behind it.
        if case .moderate = action, held.total > held.items.count {
            await loadHeld()
        }
    }

    private func isActiveAccount() async -> Bool {
        (try? await services.accounts.activeAccount())?.id == accountID
    }

    private func handleHeldWriteError(_ error: any Error, action: CommentAction) async {
        let core = error as? CoreError
        guard !(error is CancellationError), core != .cancelled, await isActiveAccount() else { return }
        if core?.hidesEntryPoint == true {
            heldPhase = .hidden
            onFeatureOff?()
            if isHollow { onHollow?() }
        } else if StudioFailure.accountState(error) != nil {
            onAccountError?(error)
        } else {
            heldMessage = (Self.heldErrorKey(error, action: action), [])
        }
    }

    private static func heldErrorKey(_ error: any Error, action: CommentAction) -> String {
        switch error as? CoreError {
        case .conflict("held_by_moderation", _): return "studio.error.held.platformHold"
        case .conflict:
            if case .report = action { return "studio.error.held.duplicateReport" }
        case .invalid("cannot_block_member"): return "studio.error.held.channelMember"
        case .signInRequired: return "studio.error.held.signIn"
        case .forbidden: return "studio.error.held.forbidden"
        case .offline: return "studio.error.offline"
        default: break
        }
        return "studio.error.held.action"
    }

    func loadQueue() async {
        await LoadPhase.run(from: queuePhase, set: { queuePhase = $0 }) {
            let studio = services.studio
            let id = channel.id
            async let drafts = studio.content(channelID: id, query: Self.query(.drafts), cursor: nil)
            async let scheduled = studio.content(channelID: id, query: Self.query(.scheduled), cursor: nil)
            async let counts = studio.contentCounts(channelID: id)
            self.drafts = try await drafts.items
            self.scheduled = try await scheduled.items
            self.counts = (try? await counts) ?? [:]
            return self.drafts.isEmpty && self.scheduled.isEmpty
        }
        reportOff(queuePhase)
    }

    private func reportOff(_ phase: LoadPhase) {
        if phase == .hidden { onFeatureOff?() }
    }

    static func query(_ status: StudioStatus) -> ContentQuery {
        ContentQuery(status: status, sort: .newest, limit: rows)
    }
}

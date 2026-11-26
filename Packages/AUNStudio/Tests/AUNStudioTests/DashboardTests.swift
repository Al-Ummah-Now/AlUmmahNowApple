import AUNCoreBridge
import AUNDesign
import Foundation
import Testing

@testable import AUNStudio

/// Content and comments answer with whatever error the test sets; everything else as the fixtures.
private struct FailingStudio: StudioServicing {
    let content: CoreError
    let comments: CoreError?
    var commentRead: (@Sendable (String) async throws -> HeldComments)?
    var commentWrite: @Sendable () async throws -> Void = {}
    private let fixtures = FixtureStudioService()

    func content(channelID: String, query: ContentQuery, cursor: String?) async throws -> ContentPage { throw content }
    func contentCounts(channelID: String) async throws -> ContentCounts { throw content }
    func heldComments(channelID: String, limit: Int, accountID: String) async throws -> HeldComments {
        if let comments { throw comments }
        if let commentRead { return try await commentRead(accountID) }
        return try await fixtures.heldComments(channelID: channelID, limit: limit, accountID: accountID)
    }
    func moderateHeldComment(_ comment: HeldComment, action: HeldCommentModeration, channelID: String, accountID: String)
        async throws
    {
        try await commentWrite()
    }
    func hideCommentAuthor(userID: String, channelID: String, accountID: String) async throws { try await commentWrite() }
    func reportHeldComment(id: String, reason: CommentReportReason, description: String?, accountID: String) async throws {
        try await commentWrite()
    }

    func channels() async throws -> [StudioChannel] { FixtureStudioService.channels }
    func playlists(channelID: String) async throws -> [StudioPlaylist] { [] }
    func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
        try await fixtures.initiateUpload(upload, channelID: channelID)
    }
    func resumeUpload(videoID: String, channelID: String) async throws -> UploadTicket {
        try await fixtures.resumeUpload(videoID: videoID, channelID: channelID)
    }
    func completeUpload(videoID: String, fileSize: Int64, channelID: String) async throws {}
    func tusEndpoint() async throws -> (url: URL, headers: [String: String]) { try await fixtures.tusEndpoint() }
    func setLanguage(_ language: VideoLanguage, videoID: String, channelID: String) async throws {}
    func addToPlaylists(_ playlistIDs: [String], videoID: String, orderKey: String, channelID: String) async throws {}
    func schedule(videoID: String, at date: Date, timeZone: TimeZone, channelID: String) async throws {}
    func updateVideo(_ id: String, _ edit: VideoEdit, channelID: String) async throws {}
    func deleteVideos(_ ids: [String], channelID: String) async throws -> BulkResult { BulkResult(items: []) }
    func bulkUpdate(_ ids: [String], _ changes: BulkChanges, channelID: String) async throws -> BulkResult {
        BulkResult(items: [])
    }
    func bulkSchedule(_ ids: [String], startAt: Date, intervalMinutes: Int, timeZone: TimeZone) async throws -> BulkResult {
        BulkResult(items: [])
    }
    func addToPlaylist(_ playlistID: String, videoIDs: [String], channelID: String) async throws {}
    func deletedVideos(channelID: String, cursor: String?) async throws -> (items: [DeletedVideo], cursor: String?) {
        ([], nil)
    }
    func restoreVideos(_ ids: [String]) async throws -> BulkResult { BulkResult(items: []) }
    func purgeVideos(_ ids: [String]) async throws -> BulkResult { BulkResult(items: []) }
    func channelStats(channelID: String, period: DateInterval) async throws -> ChannelStats { ChannelStats(totalViews: 0) }
    func videoStats(videoID: String, period: DateInterval) async throws -> VideoStats {
        VideoStats(videoID: videoID, title: "", views: 0)
    }
}

/// No hollow pages (owner review 2026-11-16): the Dashboard keeps recent uploads, comments awaiting review, and drafts
/// and scheduled; each hides on its own, and with nothing left the Dashboard goes and Studio opens on Content.
@MainActor
struct DashboardTests {
    private let accountID = FixtureAccountService.creator.id
    private let owner = FixtureStudioService.channels[0]
    private let editor = FixtureStudioService.channels[1]

    private func services(off: Set<String> = []) -> StudioServices {
        .fixtures(signedIn: true, accountState: .creator, featuresOff: off)
    }

    private func failing(
        content: CoreError, comments: CoreError?,
        accounts: FixtureAccountService = FixtureAccountService(signedIn: [FixtureAccountService.creator]),
        commentRead: (@Sendable (String) async throws -> HeldComments)? = nil,
        commentWrite: @escaping @Sendable () async throws -> Void = {}
    ) -> StudioServices {
        StudioServices(
            environment: .qa, accounts: accounts,
            studio: FailingStudio(content: content, comments: comments, commentRead: commentRead, commentWrite: commentWrite),
            transfer: FixtureTUSTransfer(),
            search: FixtureSearchService())
    }

    @Test func everySectionLoadsForTheOwner() async {
        let model = DashboardModel(accountID: accountID, channel: owner, services: services())
        var hollow = false
        model.onHollow = { hollow = true }
        await model.load()
        #expect(model.recentPhase == .ready)
        #expect(model.recent.count <= DashboardModel.rows)
        #expect(model.recent.first?.title == "Seerah, part 5")
        #expect(model.recent.first?.studioStatus == .processing)
        let dates = model.recent.map { $0.dateCreated ?? .distantPast }
        #expect(dates == dates.sorted(by: >))
        #expect(model.heldPhase == .ready)
        #expect(model.held.items.count == 2)
        #expect(model.queuePhase == .ready)
        #expect(model.drafts.map(\.title) == ["Fiqh of fasting (draft)"])
        #expect(model.scheduled.map(\.title) == ["Seerah, part 4"])
        #expect(!model.isHollow && !hollow)
    }

    @Test func approvingAndRemovingUpdateTheQueueAndPersistAcrossRefresh() async throws {
        let model = DashboardModel(accountID: accountID, channel: owner, services: services())
        await model.loadHeld()
        let initial = model.held.items
        let first = try #require(initial.first)
        let last = try #require(initial.last)

        await model.actOnHeldComment(first, action: .moderate(.approve))
        #expect(model.held == HeldComments(items: [last], total: 1))
        #expect(model.heldMessage?.key == "studio.held.approved")
        await model.loadHeld()
        #expect(model.held == HeldComments(items: [last], total: 1))

        await model.actOnHeldComment(last, action: .moderate(.remove))
        #expect(model.held == HeldComments(items: [], total: 0))
        #expect(model.heldPhase == .empty)
        #expect(model.heldMessage?.key == "studio.held.removed")
        await model.loadHeld()
        #expect(model.heldPhase == .empty)
    }

    @Test func reportingLeavesTheCommentHeldAndAllowsChildSafetyEscalation() async throws {
        let model = DashboardModel(accountID: accountID, channel: owner, services: services())
        await model.loadHeld()
        let initial = model.held
        let comment = try #require(initial.items.first)

        await model.actOnHeldComment(comment, action: .report(.spam, description: nil))
        #expect(model.heldMessage?.key == "studio.held.reported")
        await model.actOnHeldComment(comment, action: .report(.spam, description: nil))
        #expect(model.heldMessage?.key == "studio.error.held.duplicateReport")
        await model.actOnHeldComment(comment, action: .report(.childSafety, description: nil))
        #expect(model.heldMessage?.key == "studio.held.reported")
        #expect(model.held == initial)
    }

    @Test func hidingTheAuthorLeavesExistingHeldCommentsAvailable() async throws {
        let model = DashboardModel(accountID: accountID, channel: owner, services: services())
        await model.loadHeld()
        let initial = model.held
        let comment = try #require(initial.items.first)
        let userID = try #require(comment.authorUserID)

        await model.actOnHeldComment(comment, action: .hideAuthor)
        #expect(model.hiddenAuthors == [userID])
        #expect(model.heldMessage?.key == "studio.held.authorHidden")
        await model.loadHeld()
        #expect(model.held == initial)
        #expect(model.hiddenAuthors == [userID])
    }

    @Test(arguments: [HeldCommentModeration.approve, .remove])
    func failedModerationRestoresTheOptimisticallyRemovedComment(action: HeldCommentModeration) async throws {
        let (started, start) = AsyncStream<Void>.makeStream()
        let (finish, resume) = AsyncStream<Void>.makeStream()
        let services = failing(
            content: .offline, comments: nil,
            commentWrite: {
                start.yield(())
                for await _ in finish { break }
                throw CoreError.conflict("held_by_moderation")
            })
        let model = DashboardModel(accountID: accountID, channel: owner, services: services)
        await model.loadHeld()
        let initial = model.held
        let comment = try #require(initial.items.first)
        let mutation = Task { await model.actOnHeldComment(comment, action: .moderate(action)) }

        for await _ in started { break }
        #expect(model.isActingOnHeldComment)
        #expect(model.held.items == Array(initial.items.dropFirst()))
        #expect(model.held.total == initial.total - 1)
        await model.loadHeld()
        #expect(model.held.total == initial.total - 1)

        resume.yield(())
        await mutation.value
        #expect(model.held == initial)
        #expect(model.heldPhase == .ready)
        #expect(model.heldMessage?.key == "studio.error.held.platformHold")
        #expect(!model.isActingOnHeldComment)
    }

    @Test func rejectedBlockAndReportLeaveCommentsAvailableForRetry() async throws {
        let services = failing(content: .offline, comments: nil, commentWrite: { throw CoreError.forbidden })
        let model = DashboardModel(accountID: accountID, channel: owner, services: services)
        await model.loadHeld()
        let initial = model.held
        let comment = try #require(initial.items.first)

        for action in [DashboardModel.CommentAction.hideAuthor, .report(.spam, description: nil)] {
            await model.actOnHeldComment(comment, action: action)
            #expect(model.held == initial)
            #expect(model.hiddenAuthors.isEmpty)
            #expect(model.heldMessage?.key == "studio.error.held.forbidden")
            #expect(!model.isActingOnHeldComment)
        }
    }

    @Test func aStaleDashboardCannotSubmitActionsAfterSwitchingAccounts() async throws {
        let next = StudioAccount(id: "next-account")
        let accounts = FixtureAccountService(signedIn: [FixtureAccountService.creator, next])
        let services = failing(
            content: .offline, comments: nil, accounts: accounts,
            commentWrite: {
                Issue.record("A stale dashboard started a write")
            })
        let model = DashboardModel(accountID: accountID, channel: owner, services: services)
        await model.loadHeld()
        let initial = model.held
        let comment = try #require(initial.items.first)

        _ = try await accounts.switchAccount(to: next.id)
        await model.actOnHeldComment(comment, action: .report(.spam, description: nil))
        #expect(model.held == initial)
        #expect(model.heldMessage == nil)
        #expect(!model.isActingOnHeldComment)
    }

    @Test(arguments: [nil, CoreError.refused(Refusal(code: Refusal.banned))])
    func switchingAccountsDuringAnActionDiscardsTheOldResult(error: CoreError?) async throws {
        let next = StudioAccount(id: "next-account")
        let accounts = FixtureAccountService(signedIn: [FixtureAccountService.creator, next])
        let firstPage = HeldComments(items: FixtureStudioService.heldComments, total: 5)
        let nextPage = HeldComments(items: [], total: 0)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (finish, resume) = AsyncStream<Void>.makeStream()
        let reads = CommentReadLog()
        let services = failing(
            content: .offline, comments: nil, accounts: accounts,
            commentRead: { id in
                await reads.record(id)
                return id == next.id ? nextPage : firstPage
            }
        ) {
            start.yield(())
            for await _ in finish { break }
            if let error { throw error }
        }
        let oldModel = DashboardModel(accountID: accountID, channel: owner, services: services)
        oldModel.onAccountError = { _ in Issue.record("A stale write surfaced an account refusal") }
        await oldModel.loadHeld()
        let comment = try #require(oldModel.held.items.first)
        let mutation = Task { await oldModel.actOnHeldComment(comment, action: .moderate(.approve)) }

        for await _ in started { break }
        #expect(oldModel.held.total == 4)
        _ = try await accounts.switchAccount(to: next.id)
        let nextModel = DashboardModel(accountID: next.id, channel: owner, services: services)
        await nextModel.loadHeld()
        resume.yield(())
        await mutation.value

        #expect(await reads.accounts == [accountID, next.id])
        #expect(oldModel.held == firstPage)
        #expect(oldModel.heldMessage == nil)
        #expect(!oldModel.isActingOnHeldComment)
        #expect(nextModel.held == nextPage)
        #expect(nextModel.heldPhase == .empty)
        #expect(nextModel.heldMessage == nil)
        #expect(nextModel.hiddenAuthors.isEmpty)
    }

    @Test(arguments: [CoreError.featureOff, .refused(Refusal(code: Refusal.upgradeRequired))])
    func aWriteThatDisablesCommentsHidesTheSectionSilently(error: CoreError) async throws {
        let services = failing(content: .featureOff, comments: nil, commentWrite: { throw error })
        let model = DashboardModel(accountID: accountID, channel: owner, services: services)
        await model.load()
        let initial = model.held
        let comment = try #require(initial.items.first)
        var featureOff = false
        var hollow = false
        model.onFeatureOff = { featureOff = true }
        model.onHollow = { hollow = true }

        await model.actOnHeldComment(comment, action: .moderate(.remove))

        #expect(model.held == initial)
        #expect(model.heldPhase == .hidden)
        #expect(model.heldMessage == nil)
        #expect(!model.isActingOnHeldComment)
        #expect(featureOff && hollow)
    }

    @Test(arguments: [Refusal.banned, Refusal.accountPendingDeletion])
    func accountRefusalsReachTheSessionBanner(code: String) async throws {
        let refusal = Refusal(code: code)
        let services = failing(content: .offline, comments: nil, commentWrite: { throw CoreError.refused(refusal) })
        let session = StudioSession(
            services: services, authenticator: FixtureWebAuthenticator(),
            defaults: UserDefaults(suiteName: "dashboard-\(UUID().uuidString)")!)
        await session.start()
        let model = DashboardModel(accountID: accountID, channel: owner, services: services)
        model.onAccountError = { [accountID] error in session.note(error, forAccount: accountID) }
        await model.loadHeld()
        let initial = model.held
        let comment = try #require(initial.items.first)

        await model.actOnHeldComment(comment, action: .moderate(.remove))

        #expect(session.accountState == refusal)
        #expect(model.held == initial)
        #expect(model.heldPhase == .ready)
        #expect(model.heldMessage == nil)
        #expect(!model.isActingOnHeldComment)
    }

    @Test func noLoadEndsLoading() async {
        let model = DashboardModel(
            accountID: accountID, channel: owner, services: failing(content: .http(status: 500), comments: .notFound))
        await model.load()
        for phase in [model.recentPhase, model.heldPhase, model.queuePhase] { #expect(!phase.isLoading) }
        #expect(model.recentPhase == .failed && model.queuePhase == .failed)
        #expect(model.heldPhase == .empty)
    }

    @Test func commentsAreOnlyForThoseWhoReviewThem() async {
        let model = DashboardModel(accountID: accountID, channel: editor, services: services())
        #expect(model.heldPhase == .hidden)
        await model.load()
        #expect(model.heldPhase == .hidden)
        #expect(model.recentPhase == .ready)
    }

    @Test func commentsOffHidesOnlyThatSection() async {
        let model = DashboardModel(accountID: accountID, channel: owner, services: services(off: ["comments"]))
        var reread = 0
        model.onFeatureOff = { reread += 1 }
        await model.load()
        #expect(model.heldPhase == .hidden)
        #expect(model.recentPhase == .ready && model.queuePhase == .ready)
        #expect(reread == 1)
        #expect(!model.isHollow)
    }

    @Test func analyticsOffLeavesTheDashboardWhole() async {
        let model = DashboardModel(accountID: accountID, channel: owner, services: services(off: ["analytics"]))
        await model.load()
        #expect([model.recentPhase, model.heldPhase, model.queuePhase] == [.ready, .ready, .ready])
    }

    @Test func nothingLeftHidesTheDashboard() async {
        let model = DashboardModel(
            accountID: accountID, channel: owner, services: failing(content: .featureOff, comments: .featureOff))
        var hollow = false
        model.onHollow = { hollow = true }
        await model.load()
        #expect(model.isHollow && hollow)
    }

    @Test func aHollowDashboardOpensContentFirst() async {
        let session = StudioSession(
            services: services(), authenticator: FixtureWebAuthenticator(),
            defaults: UserDefaults(suiteName: "dashboard-\(UUID().uuidString)")!)
        await session.start()
        #expect(session.showsDashboard)
        session.featureOff(.home)
        #expect(!session.showsDashboard)
        #if os(iOS)
            let tabs = StudioShell.visibleTabs(for: session)
            #expect(!tabs.contains(.home))
            #expect(StudioShell.first(tabs) == .content)
            #expect(StudioShell.first(tabs.union([.home])) == .home)
        #elseif os(macOS)
            let sections = StudioShell.sections(for: session)
            #expect(!sections.contains(.home))
            #expect(StudioShell.first(sections) == .content)
            #expect(StudioShell.first(StudioSection.allCases) == .home)
        #endif
    }
}

private actor CommentReadLog {
    private(set) var accounts: [String] = []

    func record(_ accountID: String) { accounts.append(accountID) }
}

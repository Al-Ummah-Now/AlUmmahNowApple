import AUNCoreBridge
import AUNDesign
import Foundation
import Testing

@testable import AUNStudio

/// Content and comments answer with whatever error the test sets; everything else as the fixtures.
private struct FailingStudio: StudioServicing {
    let content: CoreError
    let comments: CoreError
    private let fixtures = FixtureStudioService()

    func content(channelID: String, query: ContentQuery, cursor: String?) async throws -> ContentPage { throw content }
    func contentCounts(channelID: String) async throws -> ContentCounts { throw content }
    func heldComments(channelID: String, limit: Int) async throws -> HeldComments { throw comments }

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
    private let owner = FixtureStudioService.channels[0]
    private let editor = FixtureStudioService.channels[1]

    private func services(off: Set<String> = []) -> StudioServices {
        .fixtures(signedIn: true, accountState: .creator, featuresOff: off)
    }

    private func failing(content: CoreError, comments: CoreError) -> StudioServices {
        StudioServices(
            environment: .qa, accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]),
            studio: FailingStudio(content: content, comments: comments), transfer: FixtureTUSTransfer(),
            search: FixtureSearchService())
    }

    @Test func everySectionLoadsForTheOwner() async {
        let model = DashboardModel(channel: owner, services: services())
        var hollow = false
        model.onHollow = { hollow = true }
        await model.load()
        #expect(model.recentPhase == .ready)
        #expect(model.recent.count <= DashboardModel.rows)
        #expect(model.recent.first?.title == "Daily reminder")
        #expect(model.recent.first?.studioStatus == .processing)
        let dates = model.recent.map { $0.dateCreated ?? .distantPast }
        #expect(dates == dates.sorted(by: >))
        #expect(model.heldPhase == .ready)
        #expect(model.held.items.count == 2)
        #expect(model.queuePhase == .ready)
        #expect(model.drafts.map(\.title) == ["Fiqh of Prayer"])
        #expect(model.scheduled.map(\.title) == ["Seerah overview"])
        #expect(!model.isHollow && !hollow)
    }

    @Test func noLoadEndsLoading() async {
        let model = DashboardModel(channel: owner, services: failing(content: .http(status: 500), comments: .notFound))
        await model.load()
        for phase in [model.recentPhase, model.heldPhase, model.queuePhase] { #expect(!phase.isLoading) }
        #expect(model.recentPhase == .failed && model.queuePhase == .failed)
        #expect(model.heldPhase == .empty)
    }

    @Test func commentsAreOnlyForThoseWhoReviewThem() async {
        let model = DashboardModel(channel: editor, services: services())
        #expect(model.heldPhase == .hidden)
        await model.load()
        #expect(model.heldPhase == .hidden)
        #expect(model.recentPhase == .ready)
    }

    @Test func commentsOffHidesOnlyThatSection() async {
        let model = DashboardModel(channel: owner, services: services(off: ["comments"]))
        var reread = 0
        model.onFeatureOff = { reread += 1 }
        await model.load()
        #expect(model.heldPhase == .hidden)
        #expect(model.recentPhase == .ready && model.queuePhase == .ready)
        #expect(reread == 1)
        #expect(!model.isHollow)
    }

    @Test func analyticsOffLeavesTheDashboardWhole() async {
        let model = DashboardModel(channel: owner, services: services(off: ["analytics"]))
        await model.load()
        #expect([model.recentPhase, model.heldPhase, model.queuePhase] == [.ready, .ready, .ready])
    }

    @Test func nothingLeftHidesTheDashboard() async {
        let model = DashboardModel(channel: owner, services: failing(content: .featureOff, comments: .featureOff))
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

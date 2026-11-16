import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

/// Answers `GET /api/me/features` with whatever the test sets; an error replays as a failed read.
private actor FeatureStudio: StudioServicing {
    var answer: Result<UserFeatures, CoreError>
    private(set) var reads: [String?] = []

    init(_ answer: Result<UserFeatures, CoreError>) { self.answer = answer }
    func set(_ answer: Result<UserFeatures, CoreError>) { self.answer = answer }

    func features(channelID: String?) async throws -> UserFeatures {
        reads.append(channelID)
        return try answer.get()
    }

    func channels() async throws -> [StudioChannel] { FixtureStudioService.channels }
    func playlists(channelID: String) async throws -> [StudioPlaylist] { [] }
    func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
        UploadTicket(videoID: "v1", tusSessionID: "s", chunkSize: 1 << 20)
    }
    func resumeUpload(videoID: String, channelID: String) async throws -> UploadTicket {
        UploadTicket(videoID: videoID, tusSessionID: "s2", chunkSize: 1 << 20)
    }
    func completeUpload(videoID: String, fileSize: Int64, channelID: String) async throws {}
    func tusEndpoint() async throws -> (url: URL, headers: [String: String]) {
        (URL(string: "https://fixtures.invalid/api/videos/tus")!, [:])
    }
    func setLanguage(_ language: VideoLanguage, videoID: String, channelID: String) async throws {}
    func addToPlaylists(_ playlistIDs: [String], videoID: String, orderKey: String, channelID: String) async throws {}
    func schedule(videoID: String, at date: Date, timeZone: TimeZone, channelID: String) async throws {}
}

/// The session never calls these.
extension FeatureStudio {
    func content(channelID: String, query: ContentQuery, cursor: String?) async throws -> ContentPage {
        ContentPage(items: [], cursor: nil)
    }
    func contentCounts(channelID: String) async throws -> ContentCounts { [:] }
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

/// Off, unconfigured and not-in-tier features are invisible (owner rule 2026-11-16): the session's visibility both ways.
@MainActor
struct StudioFeaturesTests {
    private func session(_ studio: any StudioServicing) -> StudioSession {
        let services = StudioServices(
            environment: .qa, accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]), studio: studio,
            transfer: FixtureTUSTransfer(), search: FixtureSearchService())
        return StudioSession(
            services: services, authenticator: FixtureWebAuthenticator(),
            defaults: UserDefaults(suiteName: "studio-features-\(UUID().uuidString)")!)
    }

    private func settle(_ until: () async -> Bool) async {
        for _ in 0..<100 {
            if await until() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func uploadShowsOnlyWhenTheFeatureIsOn() async {
        let on = session(FeatureStudio(.success(UserFeatures(on: [.upload]))))
        #expect(!on.showsUpload, "hidden until the features are read")
        await on.start()
        #expect(on.showsUpload)

        let off = session(FeatureStudio(.success(UserFeatures(on: [.bulkSchedule]))))
        await off.start()
        #expect(!off.showsUpload)
        #expect(off.shows(.bulkSchedule))
    }

    @Test func featuresAreReadForTheCurrentChannelAndAgainOnSwitch() async {
        let studio = FeatureStudio(.success(.all))
        let session = session(studio)
        await session.start()
        #expect(await studio.reads.last == "fixture-channel")
        await session.select(FixtureStudioService.channels[1])
        #expect(await studio.reads.last == "fixture-channel-2")
    }

    @Test func aFailedReadKeepsTheLastAnswerAndWithNoneEverythingStaysHidden() async {
        let failing = session(FeatureStudio(.failure(.offline)))
        await failing.start()
        #expect(failing.features == nil)
        #expect(!failing.showsUpload && !failing.shows(.bulkSchedule))

        let studio = FeatureStudio(.success(UserFeatures(on: [.upload])))
        let session = session(studio)
        await session.start()
        await studio.set(.failure(.offline))
        await session.refreshFeatures()
        #expect(session.showsUpload)
        await studio.set(.success(.none))
        await session.refreshFeatures()
        #expect(!session.showsUpload)
    }

    @Test func analyticsHidesOnFeatureOffUntilTheChannelChanges() async {
        let studio = FeatureStudio(.success(.all))
        let session = session(studio)
        await session.start()
        #expect(session.showsAnalytics)
        let before = await studio.reads.count
        session.featureOff(.analytics)
        #expect(!session.showsAnalytics)
        await settle { await studio.reads.count > before }
        #expect(await studio.reads.count == before + 1, "features are read again")
        await session.select(FixtureStudioService.channels[1])
        #expect(session.showsAnalytics)
    }

    @Test func aFeatureOffFromAnyCallReadsTheFeaturesAgain() async {
        let studio = FeatureStudio(.success(.all))
        let session = session(studio)
        await session.start()
        await studio.set(.success(UserFeatures.all.with(.bulkSchedule, false)))
        session.note(CoreError.featureOff)
        await settle { !session.shows(.bulkSchedule) }
        #expect(!session.shows(.bulkSchedule))
        #expect(session.notice == nil)
    }

    @Test func signingOutForgetsTheFeatures() async {
        let session = session(FeatureStudio(.success(.all)))
        await session.start()
        #expect(session.features == .all)
        await session.signOut(FixtureAccountService.creator.id)
        #expect(session.features == nil)
        #expect(session.hiddenSections.isEmpty)
    }

    @Test func tierAndOffAnswersHaveNoText() {
        #expect(StudioFailure.message(CoreError.featureOff) == nil)
        #expect(StudioFailure.message(CoreError.http(status: 402)) == nil)
        #expect(StudioFailure.message(CoreError.refused(Refusal(code: Refusal.upgradeRequired, message: "Pro plan"))) == nil)
        #expect(StudioFailure.message(CoreError.refused(Refusal(code: Refusal.uploadsByInvitation))) == nil)
        #expect(StudioNotice.from(CoreError.featureOff) == nil)
        // Quotas stay plain facts.
        #expect(StudioFailure.message(CoreError.refused(Refusal(code: Refusal.channelLimit)))?.key == "studio.refusal.channelLimit")
        #expect(StudioFailure.message(CoreError.http(status: 429))?.key == "studio.error.generic")
        #expect(StudioFailure.refusalMessage(Refusal(code: Refusal.accountPendingDeletion)) == "studio.account.pendingDeletion")
    }

    @Test func fixturesWithoutACreatorTierHideUpload() async {
        let session = StudioSession(
            services: .fixtures(signedIn: true, accountState: .invitation), authenticator: FixtureWebAuthenticator(),
            defaults: UserDefaults(suiteName: "studio-features-\(UUID().uuidString)")!)
        await session.start()
        #expect(!session.showsUpload)
        #expect(session.showsAnalytics)
    }
}

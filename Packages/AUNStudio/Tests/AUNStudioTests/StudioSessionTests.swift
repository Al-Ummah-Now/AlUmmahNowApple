import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

@MainActor
struct StudioSessionTests {
    private struct CancellingAuthenticator: WebAuthenticating {
        func authenticate(_ request: SignInRequest) async throws -> URL { throw CoreError.cancelled }
    }

    /// What the system sheet reports when it cannot show the sign-in page, such as a blocked domain.
    private struct BlockedAuthenticator: WebAuthenticating {
        func authenticate(_ request: SignInRequest) async throws -> URL {
            throw URLError(.cannotLoadFromNetwork)
        }
    }

    private func defaults() -> UserDefaults {
        let name = "studio-session-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func session(signedIn: Bool = false, authenticator: any WebAuthenticating = FixtureWebAuthenticator())
        -> StudioSession
    {
        StudioSession(services: .fixtures(signedIn: signedIn), authenticator: authenticator, defaults: defaults())
    }

    @Test func startsSignedOutWithoutAccounts() async {
        let session = session()
        await session.start()
        #expect(session.phase == .signedOut)
        #expect(session.channel == nil)
    }

    @Test func signInLoadsUploadableChannelsAndPicksTheMainOne() async {
        let session = session()
        await session.start()
        await session.signIn()
        #expect(session.phase == .signedIn)
        #expect(session.account?.id == FixtureAccountService.creator.id)
        #expect(session.allChannels.count == 3)
        #expect(session.channels.map(\.id) == ["fixture-channel", "fixture-channel-2"])
        #expect(session.channel?.id == "fixture-channel")
    }

    @Test func aBlockedSignInPageIsAPlainMessageAndNothingElseChanges() async {
        let session = session(authenticator: BlockedAuthenticator())
        await session.start()
        await session.signIn()
        #expect(session.phase == .signedOut)
        #expect(!session.isSigningIn)
        #expect(session.notice != nil)
    }

    @Test func thePickedChannelIsRememberedPerAccount() async {
        let store = defaults()
        let services = StudioServices.fixtures(signedIn: true)
        let first = StudioSession(services: services, authenticator: FixtureWebAuthenticator(), defaults: store)
        await first.start()
        await first.select(FixtureStudioService.channels[1])
        let second = StudioSession(services: services, authenticator: FixtureWebAuthenticator(), defaults: store)
        await second.start()
        #expect(second.channel?.id == "fixture-channel-2")
    }

    @Test func aStudioLinkPicksItsChannelAndSection() async {
        let session = session(signedIn: true)
        await session.start()
        await session.open(StudioLink(channelID: "fixture-channel-2", section: .analytics))
        #expect(session.channel?.id == "fixture-channel-2")
        #expect(session.linkedSection == .analytics)
        let serial = session.linkSerial
        session.consumeLink()
        #expect(session.linkedSection == nil)

        // A channel the account cannot upload to keeps the current one; the section still opens.
        await session.open(StudioLink(channelID: "fixture-channel-3", section: .content))
        #expect(session.channel?.id == "fixture-channel-2")
        #expect(session.linkedSection == .content)
        #expect(session.linkSerial == serial + 1)
    }

    @Test func aLinkBeforeTheChannelsLoadAppliesOnceTheyDo() async {
        let session = session(signedIn: true)
        await session.open(StudioLink(channelID: "fixture-channel-2", section: .content))
        await session.start()
        #expect(session.channel?.id == "fixture-channel-2")
        #expect(session.linkedSection == .content)
    }

    @Test func linkSectionsMapToTheShells() {
        #if os(iOS)
            #expect(StudioShell.tab(for: .deleted) == .content)
            #expect(StudioShell.tab(for: .analytics) == .analytics)
        #elseif os(macOS)
            #expect(StudioShell.section(for: .deleted) == .deleted)
            #expect(StudioShell.section(for: .home) == .home)
        #endif
    }

    @Test func cancellingSignInShowsNoError() async {
        let session = session(authenticator: CancellingAuthenticator())
        await session.start()
        await session.signIn()
        #expect(session.phase == .signedOut)
        #expect(session.notice == nil)
    }

    @Test func addingAndSwitchingAccounts() async {
        let session = session(signedIn: true)
        await session.start()
        await session.signIn(addingAccount: true)
        #expect(session.accounts.count == 2)
        #expect(session.account?.id == "fixture-account-1")
        await session.switchAccount(to: FixtureAccountService.creator.id)
        #expect(session.account?.id == FixtureAccountService.creator.id)
        #expect(session.channel != nil)
    }

    @Test func signingOutTheLastAccountReturnsToSignIn() async {
        let session = session(signedIn: true)
        await session.start()
        await session.signIn(addingAccount: true)
        await session.signOut("fixture-account-1")
        #expect(session.phase == .signedIn)
        #expect(session.account?.id == FixtureAccountService.creator.id)
        await session.signOut(FixtureAccountService.creator.id)
        #expect(session.phase == .signedOut)
        #expect(session.accounts.isEmpty)
        #expect(session.channel == nil)
    }

    private final class TermsStudioService: StudioServicing, @unchecked Sendable {
        let base = FixtureStudioService()
        var accessResult: Result<CreatorAccess, any Error> = .success(
            CreatorAccess(termsAccepted: false, termsVersion: "2026-11-24"))
        var acceptError: (any Error)?
        var acceptCalls = 0
        var acceptedVersions: [String] = []

        func channels() async throws -> [StudioChannel] { try await base.channels() }
        func playlists(channelID: String) async throws -> [StudioPlaylist] { try await base.playlists(channelID: channelID) }
        func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
            try await base.initiateUpload(upload, channelID: channelID)
        }
        func resumeUpload(videoID: String, channelID: String) async throws -> UploadTicket {
            try await base.resumeUpload(videoID: videoID, channelID: channelID)
        }
        func completeUpload(videoID: String, fileSize: Int64, channelID: String) async throws {
            try await base.completeUpload(videoID: videoID, fileSize: fileSize, channelID: channelID)
        }
        func tusEndpoint() async throws -> (url: URL, headers: [String: String]) { try await base.tusEndpoint() }
        func setLanguage(_ language: VideoLanguage, videoID: String, channelID: String) async throws {
            try await base.setLanguage(language, videoID: videoID, channelID: channelID)
        }
        func addToPlaylists(_ playlistIDs: [String], videoID: String, orderKey: String, channelID: String) async throws {
            try await base.addToPlaylists(playlistIDs, videoID: videoID, orderKey: orderKey, channelID: channelID)
        }
        func schedule(videoID: String, at date: Date, timeZone: TimeZone, channelID: String) async throws {
            try await base.schedule(videoID: videoID, at: date, timeZone: timeZone, channelID: channelID)
        }
        func content(channelID: String, query: ContentQuery, cursor: String?) async throws -> ContentPage {
            try await base.content(channelID: channelID, query: query, cursor: cursor)
        }
        func contentCounts(channelID: String) async throws -> ContentCounts { try await base.contentCounts(channelID: channelID) }
        func updateVideo(_ id: String, _ edit: VideoEdit, channelID: String) async throws {
            try await base.updateVideo(id, edit, channelID: channelID)
        }
        func deleteVideos(_ ids: [String], channelID: String) async throws -> BulkResult {
            try await base.deleteVideos(ids, channelID: channelID)
        }
        func bulkUpdate(_ ids: [String], _ changes: BulkChanges, channelID: String) async throws -> BulkResult {
            try await base.bulkUpdate(ids, changes, channelID: channelID)
        }
        func bulkSchedule(_ ids: [String], startAt: Date, intervalMinutes: Int, timeZone: TimeZone) async throws -> BulkResult {
            try await base.bulkSchedule(ids, startAt: startAt, intervalMinutes: intervalMinutes, timeZone: timeZone)
        }
        func addToPlaylist(_ playlistID: String, videoIDs: [String], channelID: String) async throws {
            try await base.addToPlaylist(playlistID, videoIDs: videoIDs, channelID: channelID)
        }
        func deletedVideos(channelID: String, cursor: String?) async throws -> (items: [DeletedVideo], cursor: String?) {
            try await base.deletedVideos(channelID: channelID, cursor: cursor)
        }
        func restoreVideos(_ ids: [String]) async throws -> BulkResult { try await base.restoreVideos(ids) }
        func purgeVideos(_ ids: [String]) async throws -> BulkResult { try await base.purgeVideos(ids) }
        func channelStats(channelID: String, period: DateInterval) async throws -> ChannelStats {
            try await base.channelStats(channelID: channelID, period: period)
        }
        func videoStats(videoID: String, period: DateInterval) async throws -> VideoStats {
            try await base.videoStats(videoID: videoID, period: period)
        }
        func creatorAccess() async throws -> CreatorAccess { try accessResult.get() }
        func acceptCreatorTerms(version: String) async throws {
            acceptCalls += 1
            acceptedVersions.append(version)
            if let acceptError { throw acceptError }
        }
    }

    @Test func creatorTermsGateHandlesErrorNilRequiredAndAccept() async {
        let studio = TermsStudioService()
        studio.accessResult = .failure(CoreError.offline)
        var services = StudioServices.fixtures(signedIn: true)
        services.studio = studio
        let session = StudioSession(services: services, authenticator: FixtureWebAuthenticator(), defaults: defaults())
        #expect(session.creatorTermsState == .loading)

        await session.start()
        #expect(session.creatorTermsState == .failed)

        // Explicit false requires acceptance
        studio.accessResult = .success(CreatorAccess(termsAccepted: false, termsVersion: "2026-11-24"))
        await session.refreshCreatorAccess()
        #expect(session.creatorTermsState == .required)
        #expect(session.termsVersion == "2026-11-24")

        // Foreground refresh while .required keeps .required (does not flash .loading)
        await session.refreshCreatorAccess()
        #expect(session.creatorTermsState == .required)

        // Failed POST stays .required and sets termsNotice without clobbering unrelated session.notice
        session.notice = StudioNotice("studio.error.signIn")
        studio.acceptError = CoreError.http(status: 503)
        let failed = await session.acceptCreatorTerms(shownVersion: "2026-11-24")
        #expect(!failed)
        #expect(session.creatorTermsState == .required)
        #expect(session.termsNotice != nil)
        #expect(session.notice?.key == "studio.error.signIn")

        // Successful POST sends the seen version, unlocks Upload, clears termsNotice, keeps unrelated notice
        studio.acceptError = nil
        let ok = await session.acceptCreatorTerms(shownVersion: "2026-11-24")
        #expect(ok)
        #expect(studio.acceptedVersions.last == "2026-11-24")
        #expect(session.creatorTermsState == .accepted)
        #expect(session.termsNotice == nil)
        #expect(session.notice?.key == "studio.error.signIn")

        // Older server omitting termsAccepted (nil) falls through to .accepted so creators are not locked out
        let compatSession = StudioSession(services: services, authenticator: FixtureWebAuthenticator(), defaults: defaults())
        studio.accessResult = .success(CreatorAccess(termsAccepted: nil))
        await compatSession.start()
        #expect(compatSession.creatorTermsState == .accepted)
    }
}

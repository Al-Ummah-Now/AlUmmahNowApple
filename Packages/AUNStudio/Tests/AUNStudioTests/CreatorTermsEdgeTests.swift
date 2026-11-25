import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

private final class BlockingUploadStudio: StudioServicing, @unchecked Sendable {
    let base = FixtureStudioService()
    var access = CreatorAccess(termsAccepted: false, termsVersion: "2026-11-24")
    var refuseUploads = true
    var initiateCalls = 0
    func channels() async throws -> [StudioChannel] { try await base.channels() }
    func playlists(channelID: String) async throws -> [StudioPlaylist] { try await base.playlists(channelID: channelID) }
    func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
        initiateCalls += 1
        if refuseUploads {
            throw CoreError.refused(Refusal(code: Refusal.termsRequired))
        }
        return try await base.initiateUpload(upload, channelID: channelID)
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
    func contentCounts(channelID: String) async throws -> ContentCounts {
        try await base.contentCounts(channelID: channelID)
    }
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
    func creatorAccess() async throws -> CreatorAccess { access }
}

private final class SlowAcceptStudio: StudioServicing, @unchecked Sendable {
    let base = FixtureStudioService()
    var accessByCall = [
        CreatorAccess(termsAccepted: false, termsVersion: "2026-11-24"),
        CreatorAccess(termsAccepted: true, termsVersion: "2026-11-24"),
    ]
    var accessCalls = 0
    var acceptStarted: CheckedContinuation<Void, Never>?
    var acceptRelease: CheckedContinuation<Void, Never>?
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
    func contentCounts(channelID: String) async throws -> ContentCounts {
        try await base.contentCounts(channelID: channelID)
    }
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
    func creatorAccess() async throws -> CreatorAccess {
        let idx = min(accessCalls, accessByCall.count - 1)
        accessCalls += 1
        return accessByCall[idx]
    }
    func acceptCreatorTerms(version: String) async throws {
        acceptStarted?.resume()
        acceptStarted = nil
        await withCheckedContinuation { cont in acceptRelease = cont }
    }
}

@MainActor
struct CreatorTermsEdgeTests {
    private func defaults() -> UserDefaults {
        let suite = "studio-terms-edge-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test func refreshClearingTermsUnblocksPausedUploadsAndIgnoresOtherAccountTermsRequired() async throws {
        let studio = BlockingUploadStudio()
        var services = StudioServices.fixtures(signedIn: true)
        services.studio = studio
        let session = StudioSession(services: services, authenticator: FixtureWebAuthenticator(), defaults: defaults())
        await session.start()

        let tmp = FileManager.default.temporaryDirectory.appending(path: "terms-unblock-\(UUID().uuidString).mp4")
        try Data([0x01, 0x02]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let job = UploadJob(
            batchID: UUID(), index: 0, file: tmp, ownsFile: false, fileSize: 2, mimeType: "video/mp4",
            title: "Test", settings: UploadSettings(), channelID: "fixture-channel",
            accountID: FixtureAccountService.creator.id)
        session.uploads.enqueue([job])
        for _ in 0..<40 where session.uploads.jobs.first?.state != .paused {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(session.uploads.isBlocked)
        #expect(session.uploads.jobs.first?.state == .paused)

        studio.refuseUploads = false
        studio.access = CreatorAccess(termsAccepted: nil)
        await session.refreshCreatorAccess()
        #expect(session.creatorTermsState == .accepted)
        #expect(!session.uploads.isBlocked)
        for _ in 0..<40 where session.uploads.jobs.first?.state != .done {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(session.uploads.jobs.first?.state == .done)

        session.requireCreatorTerms(for: "other-account-id")
        #expect(session.creatorTermsState == .accepted)
    }

    @Test func accountSwitchWhileAcceptingTermsReadsNewAccountAndDropsLatePost() async throws {
        let second = StudioAccount(id: "account-b", email: "b@example.org", displayName: "Account B")
        let accounts = FixtureAccountService(signedIn: [FixtureAccountService.creator, second])
        let studio = SlowAcceptStudio()
        var services = StudioServices.fixtures(signedIn: true)
        services.accounts = accounts
        services.studio = studio
        let session = StudioSession(services: services, authenticator: FixtureWebAuthenticator(), defaults: defaults())
        await session.start()
        #expect(session.creatorTermsState == .required)

        let acceptTask = Task { await session.acceptCreatorTerms(shownVersion: "2026-11-24") }
        await withCheckedContinuation { cont in
            if studio.acceptRelease != nil {
                cont.resume()
            } else {
                studio.acceptStarted = cont
            }
        }
        #expect(session.isAcceptingTerms)

        await session.switchAccount(to: second.id)
        #expect(!session.isAcceptingTerms)
        #expect(session.account?.id == second.id)
        #expect(session.creatorTermsState == .accepted)

        studio.acceptRelease?.resume()
        let lateResult = await acceptTask.value
        #expect(!lateResult)
        #expect(session.account?.id == second.id)
        #expect(session.creatorTermsState == .accepted)
    }

    @Test func unblockTermsIsScopedToActiveAccountAndIgnoresOtherAccountPausedJobs() async throws {
        let second = StudioAccount(id: "account-b", email: "b@example.org", displayName: "Account B")
        let accounts = FixtureAccountService(signedIn: [FixtureAccountService.creator, second])
        let studio = BlockingUploadStudio()
        studio.access = CreatorAccess(termsAccepted: false, termsVersion: "2026-11-24")
        var services = StudioServices.fixtures(signedIn: true)
        services.accounts = accounts
        services.studio = studio
        let session = StudioSession(services: services, authenticator: FixtureWebAuthenticator(), defaults: defaults())
        await session.start()

        let tmp = FileManager.default.temporaryDirectory.appending(path: "terms-scoped-\(UUID().uuidString).mp4")
        try Data([0x01, 0x02]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Account A has a pending-deletion paused job AND a terms-paused job.
        var aAccountPaused = UploadJob(
            batchID: UUID(), index: 0, file: tmp, ownsFile: false, fileSize: 2, mimeType: "video/mp4",
            title: "A deletion", settings: UploadSettings(), channelID: "fixture-channel",
            accountID: FixtureAccountService.creator.id)
        aAccountPaused.state = .paused
        aAccountPaused.failure = UploadQueue.accountStateKey
        var aTermsPaused = UploadJob(
            batchID: UUID(), index: 1, file: tmp, ownsFile: false, fileSize: 2, mimeType: "video/mp4",
            title: "A terms", settings: UploadSettings(), channelID: "fixture-channel",
            accountID: FixtureAccountService.creator.id)
        aTermsPaused.state = .paused
        aTermsPaused.failure = UploadQueue.termsRequiredKey
        session.uploads.enqueue([aAccountPaused, aTermsPaused])

        // Switch to Account B; B gets 403 terms_required on its upload.
        await session.switchAccount(to: second.id)
        let bJob = UploadJob(
            batchID: UUID(), index: 2, file: tmp, ownsFile: false, fileSize: 2, mimeType: "video/mp4",
            title: "B clip", settings: UploadSettings(), channelID: "fixture-channel", accountID: second.id)
        session.uploads.enqueue([bJob])
        for _ in 0..<60 where session.uploads.jobs.first(where: { $0.id == bJob.id })?.state != .paused {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(session.uploads.isBlocked)

        // B accepts Terms: B's job must unblock and finish; BOTH of A's jobs must remain paused!
        studio.refuseUploads = false
        let accepted = await session.acceptCreatorTerms(shownVersion: "2026-11-24")
        #expect(accepted)
        #expect(!session.uploads.isBlocked)
        for _ in 0..<60 where session.uploads.jobs.first(where: { $0.id == bJob.id })?.state != .done {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(session.uploads.jobs.first(where: { $0.id == bJob.id })?.state == .done)
        #expect(session.uploads.jobs.first(where: { $0.id == aAccountPaused.id })?.state == .paused)
        #expect(session.uploads.jobs.first(where: { $0.id == aTermsPaused.id })?.state == .paused)
        #expect(session.uploads.jobs.first(where: { $0.id == aTermsPaused.id })?.failure == UploadQueue.termsRequiredKey)
    }

    @Test func lateTermsRequiredFromPreviousAccountsUploadJobDoesNotGateNewAccount() async throws {
        let second = StudioAccount(id: "account-b", email: "b@example.org", displayName: "Account B")
        let accounts = FixtureAccountService(signedIn: [FixtureAccountService.creator, second])
        let studio = DelayedRefuseInitiateStudio()
        var services = StudioServices.fixtures(signedIn: true)
        services.accounts = accounts
        services.studio = studio
        let session = StudioSession(services: services, authenticator: FixtureWebAuthenticator(), defaults: defaults())
        await session.start()
        #expect(session.creatorTermsState == .accepted)

        let tmp = FileManager.default.temporaryDirectory.appending(path: "terms-late403-\(UUID().uuidString).mp4")
        try Data([0x01, 0x02]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let aJob = UploadJob(
            batchID: UUID(), index: 0, file: tmp, ownsFile: false, fileSize: 2, mimeType: "video/mp4",
            title: "A in-flight", settings: UploadSettings(), channelID: "fixture-channel",
            accountID: FixtureAccountService.creator.id)
        session.uploads.enqueue([aJob])
        await withCheckedContinuation { cont in
            if studio.initiateRelease != nil {
                cont.resume()
            } else {
                studio.initiateStarted = cont
            }
        }

        // Switch to Account B while A's initiateUpload is still in flight.
        await session.switchAccount(to: second.id)
        #expect(session.account?.id == second.id)
        #expect(session.creatorTermsState == .accepted)

        // Now A's initiateUpload throws 403 terms_required: B must stay accepted and unblocked.
        studio.initiateRelease?.resume()
        for _ in 0..<60 where session.uploads.jobs.first(where: { $0.id == aJob.id })?.state != .paused {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(session.account?.id == second.id)
        #expect(session.creatorTermsState == .accepted)
        #expect(!session.uploads.isBlocked)
        #expect(session.uploads.jobs.first(where: { $0.id == aJob.id })?.state == .paused)
    }
}

private final class DelayedRefuseInitiateStudio: StudioServicing, @unchecked Sendable {
    let base = FixtureStudioService()
    var initiateStarted: CheckedContinuation<Void, Never>?
    var initiateRelease: CheckedContinuation<Void, Never>?
    func channels() async throws -> [StudioChannel] { try await base.channels() }
    func playlists(channelID: String) async throws -> [StudioPlaylist] { try await base.playlists(channelID: channelID) }
    func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
        initiateStarted?.resume()
        initiateStarted = nil
        await withCheckedContinuation { cont in initiateRelease = cont }
        throw CoreError.refused(Refusal(code: Refusal.termsRequired))
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
    func creatorAccess() async throws -> CreatorAccess {
        CreatorAccess(termsAccepted: true, termsVersion: "2026-11-24")
    }
}

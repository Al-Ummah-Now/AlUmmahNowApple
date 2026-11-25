import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

private final class RecoveryStubStudio: StudioServicing, @unchecked Sendable {
    let base = FixtureStudioService()
    var access = CreatorAccess(termsAccepted: false, termsVersion: nil)
    var acceptCalls = 0
    var acceptError: CoreError?
    var refuseUploadWith: CoreError?
    func channels() async throws -> [StudioChannel] { try await base.channels() }
    func playlists(channelID: String) async throws -> [StudioPlaylist] { try await base.playlists(channelID: channelID) }
    func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
        if let error = refuseUploadWith { throw error }
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
    func acceptCreatorTerms(version: String) async throws {
        acceptCalls += 1
        if let error = acceptError { throw error }
    }
}

@MainActor
struct CreatorTermsRecoveryTests {
    private func makeSession(studio: RecoveryStubStudio) -> StudioSession {
        var services = StudioServices.fixtures(signedIn: true)
        services.studio = studio
        services.transfer = FixtureTUSTransfer(delay: .zero)
        let suite = "studio-terms-recovery-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return StudioSession(services: services, authenticator: FixtureWebAuthenticator(), defaults: store)
    }

    @Test func agreeWithNilShownVersionUnblocksWhenTermsSwitchTurnsOff() async {
        let studio = RecoveryStubStudio()
        studio.access = CreatorAccess(termsAccepted: nil, termsVersion: nil)
        let session = makeSession(studio: studio)
        await session.start()
        #expect(session.creatorTermsState == .accepted)

        // Simulate a 403 from a stale 30s memo while the read omits Terms (switch off):
        // initial refusal keeps the gate open with generic notice rather than looping.
        await session.refreshCreatorAccess(fromUploadRefusal: true)
        #expect(session.creatorTermsState == .required)
        #expect(session.termsNotice?.key == "studio.error.generic")

        // Tapping Agree (shownVersion == nil) reads termsAccepted == nil and unblocks cleanly without posting.
        let unblocked = await session.acceptCreatorTerms(shownVersion: nil)
        #expect(unblocked)
        #expect(session.creatorTermsState == .accepted)
        #expect(session.termsNotice == nil)
        #expect(studio.acceptCalls == 0)
    }

    @Test func nilVersionReadPreservesEarlierVersionAndValidVersionClearsGenericError() async {
        let studio = RecoveryStubStudio()
        studio.access = CreatorAccess(termsAccepted: nil, termsVersion: nil)
        let session = makeSession(studio: studio)
        await session.start()

        await session.refreshCreatorAccess(fromUploadRefusal: true)
        #expect(session.termsNotice?.key == "studio.error.generic")

        // Valid version arrival clears the stale generic notice without falsely flagging versionChanged.
        studio.access = CreatorAccess(termsAccepted: false, termsVersion: "2026-11-24")
        await session.refreshCreatorAccess()
        #expect(session.termsVersion == "2026-11-24")
        #expect(session.termsNotice == nil)

        // A later read omitting termsVersion preserves the known version.
        studio.access = CreatorAccess(termsAccepted: false, termsVersion: nil)
        await session.refreshCreatorAccess()
        #expect(session.termsVersion == "2026-11-24")

        // When a newer version arrives after the nil read, versionChanged fires and bumps the checkbox serial.
        let serialBefore = session.termsVersionBumpSerial
        studio.access = CreatorAccess(termsAccepted: false, termsVersion: "2026-12-01")
        await session.refreshCreatorAccess()
        #expect(session.termsVersion == "2026-12-01")
        #expect(session.termsNotice?.key == "studio.terms.versionChanged")
        #expect(session.termsVersionBumpSerial == serialBefore + 1)
    }

    @Test func repeatedUploadRefusalAutoResumeIsBounded() async {
        let studio = RecoveryStubStudio()
        studio.access = CreatorAccess(termsAccepted: true, termsVersion: "2026-11-24")
        let session = makeSession(studio: studio)
        await session.start()
        #expect(session.creatorTermsState == .accepted)

        // First two 403-triggered reads returning termsAccepted == true auto-resume.
        await session.refreshCreatorAccess(fromUploadRefusal: true)
        #expect(session.creatorTermsState == .accepted)
        await session.refreshCreatorAccess(fromUploadRefusal: true)
        #expect(session.creatorTermsState == .accepted)

        // Third consecutive refusal read stops auto-resuming so mixed isolates cannot loop forever.
        await session.refreshCreatorAccess(fromUploadRefusal: true)
        #expect(session.creatorTermsState == .required)
        #expect(session.termsNotice?.key == "studio.error.generic")
    }

    @Test func unblockTermsDoesNotClearUnrelatedAccountStateBlock() async throws {
        let studio = RecoveryStubStudio()
        studio.access = CreatorAccess(pendingDeletion: true, termsAccepted: nil, termsVersion: nil)
        studio.refuseUploadWith = .refused(Refusal(code: Refusal.accountPendingDeletion))
        let session = makeSession(studio: studio)
        await session.start()

        let tmp = FileManager.default.temporaryDirectory.appending(path: "terms-acct-block-\(UUID().uuidString).mp4")
        try Data([0x01, 0x02]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let job = UploadJob(
            batchID: UUID(), index: 0, file: tmp, ownsFile: false, fileSize: 2, mimeType: "video/mp4",
            title: "Blocked", settings: UploadSettings(), channelID: "fixture-channel",
            accountID: FixtureAccountService.creator.id)
        session.uploads.enqueue([job])
        for _ in 0..<40 where !session.uploads.isBlocked {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(session.uploads.isBlocked)
        #expect(session.uploads.jobs.first?.failure == UploadQueue.accountStateKey)

        // Remove the account-state paused job while the account remains blocked:
        // on older code without `blockedByTerms`, `unblockTerms` cleared `isBlocked` when no account-state job stayed in `jobs`.
        session.uploads.remove(job.id)
        #expect(session.uploads.jobs.isEmpty)
        #expect(session.uploads.isBlocked)

        // Refreshing access with terms off calls unblockTerms(forAccount:), which must NOT clear the account-state block.
        await session.refreshCreatorAccess()
        #expect(session.uploads.isBlocked)
    }

    @Test func noteTermsRequiredRefusalRespectsAccountAndOpensGate() async {
        let studio = RecoveryStubStudio()
        studio.access = CreatorAccess(termsAccepted: true, termsVersion: "2026-11-24")
        let session = makeSession(studio: studio)
        await session.start()
        #expect(session.creatorTermsState == .accepted)

        let refusal = Refusal(code: Refusal.termsRequired)
        #expect(StudioFailure.refusalMessage(refusal) == "studio.terms.title")

        // A late 403 from another account must NOT open the active account's gate.
        session.note(CoreError.refused(refusal), forAccount: "other-account-id")
        #expect(session.creatorTermsState == .accepted)

        // A 403 for the active account opens the gate.
        studio.access = CreatorAccess(termsAccepted: false, termsVersion: "2026-11-24")
        session.note(CoreError.refused(refusal), forAccount: FixtureAccountService.creator.id)
        #expect(session.creatorTermsState == .required)
    }

    @Test func updatedTermsStateSurvivesDismissAndAcceptErrorAndClearsOnAccept() async {
        let studio = RecoveryStubStudio()
        studio.access = CreatorAccess(termsAccepted: false, termsVersion: "2026-11-24")
        let session = makeSession(studio: studio)
        await session.start()
        #expect(!session.termsUpdatedWhileOpen)

        // 409 terms_version_changed sets termsUpdatedWhileOpen = true.
        studio.acceptError = .refused(Refusal(code: Refusal.termsVersionChanged, currentVersion: "2026-12-01"))
        let conflict = await session.acceptCreatorTerms(shownVersion: "2026-11-24")
        #expect(!conflict)
        #expect(session.termsUpdatedWhileOpen)
        #expect(session.termsVersion == "2026-12-01")

        // Dismissing the notice keeps updated-terms copy active.
        session.termsNotice = nil
        #expect(session.termsUpdatedWhileOpen)

        // A failed Agree replacing the notice with an error still keeps updated-terms copy active.
        studio.acceptError = .http(status: 503)
        let failed = await session.acceptCreatorTerms(shownVersion: "2026-12-01")
        #expect(!failed)
        #expect(session.termsNotice?.key == "studio.error.generic")
        #expect(session.termsUpdatedWhileOpen)

        // Accepting clears termsUpdatedWhileOpen.
        studio.acceptError = nil
        let accepted = await session.acceptCreatorTerms(shownVersion: "2026-12-01")
        #expect(accepted)
        #expect(!session.termsUpdatedWhileOpen)
    }

    @Test func uploadJobRowHidesResumeOnlyWhileTermsGateIsOpen() {
        let url = URL(fileURLWithPath: "/tmp/clip.mp4")
        var termsPaused = UploadJob(
            batchID: UUID(), index: 0, file: url, ownsFile: false, fileSize: 2, mimeType: "video/mp4",
            title: "Clip", settings: UploadSettings(), channelID: "ch", accountID: "a")
        termsPaused.state = .paused
        termsPaused.failure = UploadQueue.termsRequiredKey

        #expect(UploadJobRow.pausedStatusKey(for: termsPaused) == "studio.upload.state.waitingForTerms")
        #expect(!UploadJobRow.showsResumeAction(for: termsPaused, isTermsGateOpen: true))
        #expect(UploadJobRow.showsResumeAction(for: termsPaused, isTermsGateOpen: false))

        var manualPaused = termsPaused
        manualPaused.failure = nil
        #expect(UploadJobRow.pausedStatusKey(for: manualPaused) == "studio.upload.state.paused")
        #expect(UploadJobRow.showsResumeAction(for: manualPaused, isTermsGateOpen: true))
    }
}

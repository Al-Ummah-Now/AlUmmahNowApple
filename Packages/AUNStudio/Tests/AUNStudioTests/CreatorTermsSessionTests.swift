import AUNCoreBridge
import AUNDesign
import Foundation
import Testing

@testable import AUNStudio

@MainActor
struct CreatorTermsSessionTests {
    private actor StubStudioService: StudioServicing {
        private let base = FixtureStudioService()
        var nextAccess: Result<CreatorAccess, Error> = .success(
            CreatorAccess(
                canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: false,
                termsVersion: "2026-11-24"))
        var nextAccept: Result<Void, Error> = .success(())
        var refuseNextInitiate: CoreError?
        var acceptCalls = 0
        var accessCalls = 0
        var acceptedVersions: [String] = []
        var initiateCalls = 0
        var delayAccessNs: UInt64 = 0
        var delayAcceptNs: UInt64 = 0

        func setAccess(_ result: Result<CreatorAccess, Error>, delayNs: UInt64 = 0) {
            nextAccess = result
            delayAccessNs = delayNs
        }

        func setAccept(_ result: Result<Void, Error>, delayNs: UInt64 = 0) {
            nextAccept = result
            delayAcceptNs = delayNs
        }

        func setRefuseNextInitiate(_ error: CoreError?) {
            refuseNextInitiate = error
        }

        func channels() async throws -> [StudioChannel] { try await base.channels() }
        func playlists(channelID: String) async throws -> [StudioPlaylist] { try await base.playlists(channelID: channelID) }
        func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
            initiateCalls += 1
            if let error = refuseNextInitiate {
                refuseNextInitiate = nil
                throw error
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
        func features(channelID: String?) async throws -> UserFeatures { try await base.features(channelID: channelID) }
        func heldComments(channelID: String, limit: Int) async throws -> HeldComments {
            try await base.heldComments(channelID: channelID, limit: limit)
        }

        func creatorAccess() async throws -> CreatorAccess {
            accessCalls += 1
            if delayAccessNs > 0 { try? await Task.sleep(nanoseconds: delayAccessNs) }
            return try nextAccess.get()
        }

        func acceptCreatorTerms(version: String) async throws {
            acceptCalls += 1
            acceptedVersions.append(version)
            if delayAcceptNs > 0 { try? await Task.sleep(nanoseconds: delayAcceptNs) }
            try nextAccept.get()
        }
    }

    private func makeSession(studio: StubStudioService) -> StudioSession {
        var services = StudioServices.fixtures(signedIn: true)
        services.studio = studio
        services.transfer = FixtureTUSTransfer(delay: .zero)
        return StudioSession(
            services: services,
            authenticator: FixtureWebAuthenticator(),
            defaults: UserDefaults(suiteName: "terms-\(UUID().uuidString)")!
        )
    }

    @Test func failedRefreshKeepsRequiredStateAndNeverWipesGate() async {
        let stub = StubStudioService()
        let session = makeSession(studio: stub)
        await session.start()
        #expect(session.creatorTermsState == .required)

        // Returning offline from Safari Terms page must keep `.required`, not replace with `.failed`.
        await stub.setAccess(.failure(CoreError.offline))
        await session.refreshCreatorAccess()
        #expect(session.creatorTermsState == .required)
    }

    @Test func acceptedFlipsBackToRequiredWhenServerReturnsFalseAndIgnoresStaleLoad() async {
        let stub = StubStudioService()
        let session = makeSession(studio: stub)
        await session.start()
        #expect(session.creatorTermsState == .required)

        // Start a slow refresh returning false, then accept before it resolves: accept must win.
        await stub.setAccess(
            .success(CreatorAccess(canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: false)),
            delayNs: 80_000_000)
        let slowRefresh = Task { await session.refreshCreatorAccess() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let ok = await session.acceptCreatorTerms(shownVersion: "2026-11-24")
        #expect(ok)
        #expect(session.creatorTermsState == .accepted)
        await slowRefresh.value
        #expect(session.creatorTermsState == .accepted)

        // A later refresh returning false (newer Terms version) re-gates the account.
        await stub.setAccess(
            .success(CreatorAccess(canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: false)))
        await session.refreshCreatorAccess()
        #expect(session.creatorTermsState == .required)
    }

    @Test func failedInitialLoadAllowsUploadAndSignOutDropsInFlightAccept() async {
        let stub = StubStudioService()
        await stub.setAccess(.failure(CoreError.offline))
        let session = makeSession(studio: stub)
        await session.start()
        #expect(session.creatorTermsState == .failed)
        #expect(!session.needsCreatorTerms)

        // Recover to required, start slow accept, sign out before it returns: must not mark accepted.
        await stub.setAccess(
            .success(
                CreatorAccess(
                    canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: false,
                    termsVersion: "2026-11-24")))
        await session.refreshCreatorAccess()
        #expect(session.creatorTermsState == .required)

        await stub.setAccept(.success(()), delayNs: 80_000_000)
        let slowAccept = Task { await session.acceptCreatorTerms(shownVersion: "2026-11-24") }
        try? await Task.sleep(nanoseconds: 10_000_000)
        if let id = session.account?.id { await session.signOut(id) }
        let accepted = await slowAccept.value
        #expect(!accepted)
        #expect(session.creatorTermsState == .loading)
        #expect(session.termsVersion == nil)
    }

    @Test func termsRequiredRefusalOnUploadOpensGateAndAcceptResumesJob() async throws {
        let stub = StubStudioService()
        await stub.setAccess(
            .success(
                CreatorAccess(
                    canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: true,
                    termsVersion: "2026-11-24")))
        await stub.setRefuseNextInitiate(.refused(Refusal(code: Refusal.termsRequired)))
        let session = makeSession(studio: stub)
        await session.start()
        #expect(session.creatorTermsState == .accepted)

        // Server now requires acceptance of Creator Terms and refuses upload with 403 terms_required.
        await stub.setAccess(
            .success(
                CreatorAccess(
                    canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: false,
                    termsVersion: "2026-11-24")))

        let url = FileManager.default.temporaryDirectory.appending(path: "terms-resume-\(UUID().uuidString).mp4")
        try Data(repeating: 9, count: 64).write(to: url)
        let job = UploadJob(
            batchID: UUID(), index: 0, file: url, ownsFile: true, fileSize: 64, mimeType: "video/mp4",
            title: "Clip", settings: UploadSettings(), channelID: "fixture-channel",
            accountID: FixtureAccountService.creator.id)
        session.uploads.enqueue([job])

        // Wait for upload to pause on 403 terms_required and open the gate.
        for _ in 0..<200 {
            if session.creatorTermsState == .required && session.uploads.jobs.first?.state == .paused { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.creatorTermsState == .required)
        #expect(session.uploads.jobs.first?.state == .paused)
        #expect(session.uploads.jobs.first?.failure == UploadQueue.termsRequiredKey)

        // Accepting terms sends the version, unblocks the queue and finishes the paused upload.
        let ok = await session.acceptCreatorTerms(shownVersion: "2026-11-24")
        #expect(ok)
        #expect(await stub.acceptedVersions == ["2026-11-24"])
        #expect(session.creatorTermsState == .accepted)
        for _ in 0..<200 {
            if session.uploads.jobs.first?.state == .done { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.uploads.jobs.first?.state == .done)
        #expect(await stub.initiateCalls == 2)
    }

    @Test func versionConflictUpdatesVersionAndBumpsCheckboxResetAndFeatureOffClearsGate() async {
        let stub = StubStudioService()
        let session = makeSession(studio: stub)
        await session.start()
        #expect(session.creatorTermsState == .required)
        #expect(session.termsVersion == "2026-11-24")
        let initialSerial = session.termsVersionBumpSerial

        // 409 terms_version_changed keeps gate open, updates version, bumps reset serial, shows notice.
        await stub.setAccept(
            .failure(CoreError.refused(Refusal(code: Refusal.termsVersionChanged, currentVersion: "2026-12-01"))))
        let conflict = await session.acceptCreatorTerms(shownVersion: "2026-11-24")
        #expect(!conflict)
        #expect(await stub.acceptedVersions == ["2026-11-24"])
        #expect(session.creatorTermsState == .required)
        #expect(session.termsVersion == "2026-12-01")
        #expect(session.termsVersionBumpSerial == initialSerial + 1)
        #expect(session.termsNotice?.key == "studio.terms.versionChanged")

        // Foreground refresh returning an even newer version while open also bumps serial and notices.
        await stub.setAccess(
            .success(
                CreatorAccess(
                    canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: false,
                    termsVersion: "2027-01-01")))
        await session.refreshCreatorAccess()
        #expect(session.termsVersion == "2027-01-01")
        #expect(session.termsVersionBumpSerial == initialSerial + 2)
        #expect(session.termsNotice?.key == "studio.terms.versionChanged")

        // 404 feature_off when server turns creatorTerms off clears the gate instead of stranding the user.
        await stub.setAccept(.failure(CoreError.featureOff))
        let off = await session.acceptCreatorTerms(shownVersion: "2027-01-01")
        #expect(off)
        #expect(session.creatorTermsState == .accepted)
        #expect(session.termsNotice == nil)
    }

    @Test func allTermsAndSupportLinkStringsLocalizeWithoutMissingKeys() {
        let keys = [
            "studio.terms.title",
            "studio.terms.body",
            "studio.terms.checkbox",
            "studio.terms.agree",
            "studio.terms.saving",
            "studio.terms.versionChanged",
            UploadQueue.termsRequiredKey,
            "studio.error.generic",
            "studio.error.offline",
            "common.error.load",
            "common.help",
            "common.contact",
            "common.privacyPolicy",
            "common.termsOfService",
            "common.communityGuidelines",
        ]
        for language in AppLanguage.allCases {
            let l10n = L10n(language)
            for key in keys {
                let value = l10n(key)
                #expect(!value.contains("⟦"), "Missing \(language.rawValue) string for \(key): \(value)")
                #expect(!value.isEmpty, "Empty \(language.rawValue) string for \(key)")
            }
        }
    }

    @Test func supportLinksUseEnvironmentHostsAcrossQAStageAndProd() {
        let qa = AppEnvironment.qa
        #expect(qa.webBaseURL.absoluteString == "https://videos.qa.alummahnow.net")
        #expect(qa.wwwBaseURL.absoluteString == "https://www.qa.alummahnow.net")
        #expect(
            AUNSupportLinks.help(language: "en", environment: qa).absoluteString == "https://videos.qa.alummahnow.net/en/help")
        #expect(
            AUNSupportLinks.privacy(language: "ar", environment: qa).absoluteString == "https://www.qa.alummahnow.net/ar/privacy/"
        )

        let stage = AppEnvironment(
            name: "stage",
            apiBaseURL: URL(string: "https://videos.api.stage.alummahnow.net")!,
            adminAPIBaseURL: URL(string: "https://admin.api.stage.alummahnow.net")!,
            authIssuer: URL(string: "https://auth.stage.alummahnow.net")!)
        #expect(stage.webBaseURL.absoluteString == "https://videos.stage.alummahnow.net")
        #expect(stage.wwwBaseURL.absoluteString == "https://www.stage.alummahnow.net")

        let prod = AppEnvironment(
            name: "prod",
            apiBaseURL: URL(string: "https://videos.api.alummahnow.net")!,
            adminAPIBaseURL: URL(string: "https://admin.api.alummahnow.net")!,
            authIssuer: URL(string: "https://auth.alummahnow.net")!)
        #expect(prod.webBaseURL.absoluteString == "https://videos.alummahnow.net")
        #expect(prod.wwwBaseURL.absoluteString == "https://www.alummahnow.net")
        #expect(AUNSupportLinks.terms(language: "en", environment: prod).absoluteString == "https://www.alummahnow.net/en/terms/")
    }

    @Test func agreeWithoutShownVersionFetchesAndShowsFirstWithoutPosting() async {
        let stub = StubStudioService()
        await stub.setAccess(.failure(CoreError.offline))
        let session = makeSession(studio: stub)
        await session.start()
        #expect(session.termsVersion == nil)

        // Upload refusal opens gate while GET still fails: wait deterministically for the failed GET call.
        let callsBefore = await stub.accessCalls
        session.requireCreatorTerms(for: FixtureAccountService.creator.id)
        for _ in 0..<100 where await stub.accessCalls == callsBefore {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await Task.yield()
        #expect(session.creatorTermsState == .required)
        #expect(session.termsVersion == nil)
        let serialBefore = session.termsVersionBumpSerial

        // Server recovers; tapping Agree without a shown version must fetch & show it, bump reset serial, and NOT POST.
        await stub.setAccess(
            .success(
                CreatorAccess(
                    canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: false,
                    termsVersion: "2026-12-01")))
        let firstTap = await session.acceptCreatorTerms(shownVersion: nil)
        #expect(!firstTap)
        #expect(await stub.acceptCalls == 0)
        #expect(session.creatorTermsState == .required)
        #expect(session.termsVersion == "2026-12-01")
        #expect(session.termsVersionBumpSerial == serialBefore + 1)
        #expect(!session.termsUpdatedWhileOpen)
        #expect(session.termsNotice == nil)

        // Even with session.termsVersion now known, a nil shownVersion tap must NEVER fall back and post it.
        let nilWithKnown = await session.acceptCreatorTerms(shownVersion: nil)
        #expect(!nilWithKnown)
        #expect(await stub.acceptCalls == 0)

        // Second tap after seeing the version posts it once and completes.
        let secondTap = await session.acceptCreatorTerms(shownVersion: "2026-12-01")
        #expect(secondTap)
        #expect(await stub.acceptedVersions == ["2026-12-01"])
        #expect(session.creatorTermsState == .accepted)
    }

    @Test func arrivalOfFirstVersionWhileGateOpenBumpsResetSerialToDropPrematureTick() async {
        let stub = StubStudioService()
        await stub.setAccess(.failure(CoreError.offline))
        let session = makeSession(studio: stub)
        await session.start()
        let callsBefore = await stub.accessCalls
        session.requireCreatorTerms(for: FixtureAccountService.creator.id)
        for _ in 0..<100 where await stub.accessCalls == callsBefore {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await Task.yield()
        #expect(session.termsVersion == nil)
        let serialBefore = session.termsVersionBumpSerial

        await stub.setAccess(
            .success(
                CreatorAccess(
                    canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: false,
                    termsVersion: "2026-11-24")))
        await session.refreshCreatorAccess()
        #expect(session.termsVersion == "2026-11-24")
        #expect(session.termsVersionBumpSerial == serialBefore + 1)
    }

    @Test func refusalWithKnownVersionReReadsLatestVersionBeforeAgree() async throws {
        let stub = StubStudioService()
        await stub.setAccess(
            .success(
                CreatorAccess(
                    canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: true,
                    termsVersion: "2026-11-24")))
        let session = makeSession(studio: stub)
        await session.start()
        #expect(session.termsVersion == "2026-11-24")

        // Server bumps Terms to 2026-12-01 and refuses upload with 403 terms_required.
        await stub.setAccess(
            .success(
                CreatorAccess(
                    canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: false,
                    termsVersion: "2026-12-01")))
        session.requireCreatorTerms(for: FixtureAccountService.creator.id)
        for _ in 0..<50 where session.termsVersion != "2026-12-01" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.creatorTermsState == .required)
        #expect(session.termsVersion == "2026-12-01")
        let ok = await session.acceptCreatorTerms(shownVersion: "2026-12-01")
        #expect(ok)
        #expect(await stub.acceptedVersions == ["2026-12-01"])
    }

    @Test func uploadRefusalReadOmittingTermsAcceptedDoesNotUnblockOrLoop() async throws {
        let stub = StubStudioService()
        await stub.setAccess(
            .success(
                CreatorAccess(
                    canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: true,
                    termsVersion: "2026-11-24")))
        let session = makeSession(studio: stub)
        await session.start()

        // Next GET omits termsAccepted (nil) while upload returns 403 terms_required.
        await stub.setAccess(
            .success(CreatorAccess(canUpload: true, canCreateChannel: true, pendingDeletion: false, termsAccepted: nil)))
        await stub.setRefuseNextInitiate(.refused(Refusal(code: Refusal.termsRequired)))
        let url = FileManager.default.temporaryDirectory.appending(path: "terms-noloop-\(UUID().uuidString).mp4")
        try Data(repeating: 4, count: 32).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let job = UploadJob(
            batchID: UUID(), index: 0, file: url, ownsFile: false, fileSize: 32, mimeType: "video/mp4",
            title: "Loop check", settings: UploadSettings(), channelID: "fixture-channel",
            accountID: FixtureAccountService.creator.id)
        session.uploads.enqueue([job])
        for _ in 0..<80 where session.termsNotice == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(120))
        #expect(await stub.initiateCalls == 1)
        #expect(session.creatorTermsState == .required)
        #expect(session.uploads.isBlocked)
        #expect(session.uploads.jobs.first?.state == .paused)
        #expect(session.termsNotice?.key == "studio.error.generic")
    }
}

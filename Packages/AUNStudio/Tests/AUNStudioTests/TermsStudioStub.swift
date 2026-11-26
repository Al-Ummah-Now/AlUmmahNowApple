import AUNCoreBridge
import Foundation

@testable import AUNStudio

/// The server of the Creator Terms tests: what it answers, what it was asked, and calls it holds until a test lets go.
actor TermsStudioStub: StudioServicing {
    enum Call { case access, accept, initiate }

    private let base = FixtureStudioService()
    private var access: Result<CreatorAccess, any Error>
    private var accept: Result<Void, any Error> = .success(())
    private var uploadRefusals = 0
    private var uploadError: CoreError = .refused(Refusal(code: Refusal.termsRequired))
    private var held: Set<Call> = []
    private var waiting: [Call: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var reads = 0
    private(set) var posted: [String] = []
    private(set) var initiated = 0

    init(_ access: CreatorAccess) { self.access = .success(access) }

    func answer(_ access: CreatorAccess) { self.access = .success(access) }
    func failReads(_ error: CoreError = .offline) { access = .failure(error) }
    func acceptFails(_ error: CoreError?) { accept = error.map { .failure($0) } ?? .success(()) }
    /// The next `count` uploads are refused.
    func refuseUploads(_ count: Int = .max, with error: CoreError = .refused(Refusal(code: Refusal.termsRequired))) {
        uploadRefusals = count
        uploadError = error
    }

    func hold(_ call: Call) { held.insert(call) }
    func isHolding(_ call: Call) -> Bool { waiting[call]?.isEmpty == false }
    func release(_ call: Call) {
        held.remove(call)
        waiting.removeValue(forKey: call)?.forEach { $0.resume() }
    }

    private func pass(_ call: Call) async {
        guard held.contains(call) else { return }
        await withCheckedContinuation { waiting[call, default: []].append($0) }
    }

    func creatorAccess() async throws -> CreatorAccess {
        reads += 1
        // The server answers when it is asked; a held answer arrives late.
        let answer = access
        await pass(.access)
        return try answer.get()
    }

    func acceptCreatorTerms(version: String) async throws {
        posted.append(version)
        await pass(.accept)
        try accept.get()
    }

    func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
        initiated += 1
        let refused = uploadRefusals > 0
        if refused, uploadRefusals != .max { uploadRefusals -= 1 }
        await pass(.initiate)
        if refused { throw uploadError }
        return try await base.initiateUpload(upload, channelID: channelID)
    }

    func channels() async throws -> [StudioChannel] { try await base.channels() }
    func playlists(channelID: String) async throws -> [StudioPlaylist] { try await base.playlists(channelID: channelID) }
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
    func heldComments(channelID: String, limit: Int, accountID: String) async throws -> HeldComments {
        try await base.heldComments(channelID: channelID, limit: limit, accountID: accountID)
    }
}

extension CreatorAccess {
    static func terms(_ accepted: Bool?, _ version: String? = "2026-11-24") -> CreatorAccess {
        CreatorAccess(termsAccepted: accepted, termsVersion: version)
    }
}

@MainActor
enum TermsTest {
    static let accountA = FixtureAccountService.creator.id
    static let accountB = StudioAccount(id: "account-b", email: "b@example.org", displayName: "Account B")
    static let refusal = CoreError.refused(Refusal(code: Refusal.termsRequired))
    static func changed(to version: String?) -> CoreError {
        .refused(Refusal(code: Refusal.termsVersionChanged, currentVersion: version))
    }

    static func session(_ studio: TermsStudioStub, transfer: (any TUSTransferring)? = nil) -> StudioSession {
        var services = StudioServices.fixtures(signedIn: true)
        services.accounts = FixtureAccountService(signedIn: [FixtureAccountService.creator, accountB])
        services.studio = studio
        services.transfer = transfer ?? FixtureTUSTransfer(delay: .zero)
        return StudioSession(
            services: services, authenticator: FixtureWebAuthenticator(),
            defaults: UserDefaults(suiteName: "terms-\(UUID().uuidString)")!)
    }

    static func started(_ studio: TermsStudioStub) async -> StudioSession {
        let session = session(studio)
        await session.start()
        return session
    }

    /// A small file waiting to go up; Studio deletes it when it is done.
    static func job(_ index: Int = 0, account: String = accountA) throws -> UploadJob {
        let url = FileManager.default.temporaryDirectory.appending(path: "terms-\(UUID().uuidString).mp4")
        try Data(repeating: 7, count: 32).write(to: url)
        return UploadJob(
            batchID: UUID(), index: index, file: url, ownsFile: true, fileSize: 32, mimeType: "video/mp4", title: "Clip",
            settings: UploadSettings(), channelID: "fixture-channel", accountID: account)
    }

    static func until(_ condition: () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Agrees, as a tap on the box and on the button does.
    static func agree(_ session: StudioSession) async -> Bool {
        session.setTermsAgreed(true)
        return await session.acceptCreatorTerms()
    }
}

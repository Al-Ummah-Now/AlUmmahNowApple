import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

/// A transfer whose chunks (or create) can hang until cancelled, and that can be slow while still reporting progress.
private final class StallingTransfer: TUSTransferring, @unchecked Sendable {
    var onOrphanCompletion: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var _hangingSends: Int
    private var _sends = 0
    private var _creates = 0
    private var stored: Int64 = 0
    private let slowSendFor: Duration
    private let progressEvery: Duration
    private let hangingCreate: Bool
    /// A hanging chunk that the server nevertheless received in full (the answer was lost).
    private let landsBeforeHanging: Bool
    /// What a later offset question does: answer, never answer, or say the session is gone.
    enum OffsetAnswer { case server, hangs, gone }
    private var _offsetAnswer: OffsetAnswer = .server
    private var _sentOffsets: [Int64] = []

    init(
        hangingSends: Int, slowSendFor: Duration = .zero, progressEvery: Duration = .milliseconds(30),
        hangingCreate: Bool = false,
        landsBeforeHanging: Bool = false
    ) {
        _hangingSends = hangingSends
        self.slowSendFor = slowSendFor
        self.progressEvery = progressEvery
        self.hangingCreate = hangingCreate
        self.landsBeforeHanging = landsBeforeHanging
    }

    var offsetAnswer: OffsetAnswer {
        get { lock.withLock { _offsetAnswer } }
        set { lock.withLock { _offsetAnswer = newValue } }
    }
    /// The offset of every chunk sent, in order
    var sentOffsets: [Int64] { lock.withLock { _sentOffsets } }

    var hangingSends: Int {
        get { lock.withLock { _hangingSends } }
        set { lock.withLock { _hangingSends = newValue } }
    }
    var sends: Int { lock.withLock { _sends } }
    var creates: Int { lock.withLock { _creates } }

    func create(endpoint: URL, headers: [String: String], size: Int64, metadata: [String: String]) async throws -> URL {
        lock.withLock { _creates += 1 }
        if hangingCreate { try await Task.sleep(for: .seconds(30)) }
        return endpoint.appending(path: "upload-1")
    }

    func offset(of url: URL, headers: [String: String]) async throws -> Int64 {
        switch offsetAnswer {
        case .server: return lock.withLock { stored }
        case .hangs:
            try await Task.sleep(for: .seconds(30))
            return 0
        case .gone: throw CoreError.notFound
        }
    }

    func send(
        chunk file: URL, to url: URL, offset: Int64, headers: [String: String], progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path())[.size]) as? NSNumber)?.int64Value ?? 0
        let hang = lock.withLock { () -> Bool in
            _sends += 1
            _sentOffsets.append(offset)
            guard _hangingSends > 0 else { return false }
            _hangingSends -= 1
            return true
        }
        // Honours cancellation, as URLSession does
        if hang {
            if landsBeforeHanging { lock.withLock { stored = offset + size } }
            try await Task.sleep(for: .seconds(30))
        }
        if slowSendFor > .zero {
            let steps = max(1, Int(slowSendFor / progressEvery))
            for step in 1...steps {
                try await Task.sleep(for: progressEvery)
                progress(size * Int64(step) / Int64(steps))
            }
        }
        lock.withLock { stored = offset + size }
        return offset + size
    }
}

/// Records Studio calls; can refuse the first initiate.
private actor RecordingStudio: StudioServicing {
    var calls: [String] = []
    var refuseInitiate: CoreError?

    init(refuseInitiate: CoreError? = nil) { self.refuseInitiate = refuseInitiate }

    func channels() async throws -> [StudioChannel] { FixtureStudioService.channels }
    func playlists(channelID: String) async throws -> [StudioPlaylist] { [] }
    func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
        calls.append("initiate:\(upload.title):public=\(upload.isPublic)")
        if let error = refuseInitiate {
            refuseInitiate = nil
            throw error
        }
        return UploadTicket(videoID: "v-\(upload.title)", tusSessionID: "s", chunkSize: 1 << 20)
    }
    func resumeUpload(videoID: String, channelID: String) async throws -> UploadTicket {
        UploadTicket(videoID: videoID, tusSessionID: "s2", chunkSize: 1 << 20)
    }
    func completeUpload(videoID: String, fileSize: Int64, channelID: String) async throws {
        calls.append("complete:\(videoID):\(fileSize)")
    }
    func tusEndpoint() async throws -> (url: URL, headers: [String: String]) {
        (URL(string: "https://fixtures.invalid/api/videos/tus")!, [:])
    }
    func setLanguage(_ language: VideoLanguage, videoID: String, channelID: String) async throws {
        calls.append("language:\(language.rawValue)")
    }
    func addToPlaylists(_ playlistIDs: [String], videoID: String, orderKey: String, channelID: String) async throws {
        calls.append("playlists:\(playlistIDs.joined(separator: ","))")
    }
    func schedule(videoID: String, at date: Date, timeZone: TimeZone, channelID: String) async throws {
        calls.append("schedule:\(videoID)")
    }
}

@MainActor
struct UploadQueueTests {
    private func file(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func store() -> UploadStore {
        UploadStore(url: FileManager.default.temporaryDirectory.appending(path: "q-\(UUID().uuidString).json"))
    }

    private func job(_ file: URL, title: String, settings: UploadSettings = UploadSettings(), account: String = "a1")
        -> UploadJob
    {
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return UploadJob(
            batchID: UUID(), index: 0, file: file, ownsFile: true, fileSize: size, mimeType: "video/mp4", title: title,
            settings: settings, channelID: "c1", accountID: account)
    }

    private func waitUntilIdle(_ queue: UploadQueue) async throws {
        for _ in 0..<200 {
            if !queue.jobs.contains(where: { $0.state == .waiting || $0.isActive }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("queue did not settle")
    }

    @Test func runsEveryStepInOrderAndDeletesItsCopy() async throws {
        let studio = RecordingStudio()
        let queue = UploadQueue(studio: studio, transfer: FixtureTUSTransfer(delay: .zero), store: store())
        queue.accountID = "a1"
        let source = try file(bytes: 2_500_000)
        let settings = UploadSettings(
            language: .ar, playlistIDs: ["p1"], scheduleAt: Date().addingTimeInterval(3600))
        queue.enqueue([job(source, title: "One", settings: settings)])
        try await waitUntilIdle(queue)
        let done = try #require(queue.jobs.first)
        #expect(done.state == .done)
        #expect(done.offset == 2_500_000)
        #expect(done.fraction == 1)
        #expect(!FileManager.default.fileExists(atPath: source.path()))
        #expect(
            await studio.calls == [
                "initiate:One:public=false", "language:ar", "playlists:p1", "complete:v-One:2500000", "schedule:v-One",
            ])
    }

    @Test func aPendingDeletionPausesTheQueueUntilTheAccountIsRestored() async throws {
        let studio = RecordingStudio(refuseInitiate: .refused(Refusal(code: Refusal.accountPendingDeletion)))
        let queue = UploadQueue(studio: studio, transfer: FixtureTUSTransfer(delay: .zero), store: store())
        var reported: Refusal?
        queue.onAccountState = { reported = $0 }
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 10), title: "Three")])
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .paused)
        #expect(queue.jobs[0].failure == UploadQueue.accountStateKey)
        #expect(queue.isBlocked)
        #expect(reported?.code == Refusal.accountPendingDeletion)
        queue.unblock()
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .done)
    }

    @Test func aTierRefusalSaysNothingAndAsksForTheFeaturesAgain() async throws {
        // No creator tier, upload switched off, or a plan refusal: no text, the job goes, and Studio reads its features
        // again so the Upload tab disappears.
        let refusals: [CoreError] = [
            .refused(Refusal(code: Refusal.uploadsByInvitation)), .featureOff, .http(status: 402),
            .refused(Refusal(code: Refusal.upgradeRequired, message: "On the Pro plan.")),
        ]
        for refusal in refusals {
            let studio = RecordingStudio(refuseInitiate: refusal)
            let queue = UploadQueue(studio: studio, transfer: FixtureTUSTransfer(delay: .zero), store: store())
            var asked = 0
            queue.onFeatureOff = { asked += 1 }
            queue.accountID = "a1"
            queue.enqueue([job(try file(bytes: 10), title: "Four")])
            try await waitUntilIdle(queue)
            #expect(queue.jobs.isEmpty, "\(refusal)")
            #expect(asked == 1, "\(refusal)")
        }
        #expect(UploadQueue.failureKey(CoreError.refused(Refusal(code: Refusal.uploadsByInvitation))) == nil)
        #expect(UploadQueue.failureKey(CoreError.forbidden) == "studio.upload.error.forbidden")
        #expect(UploadQueue.failureKey(CoreError.refused(Refusal(code: Refusal.uploadLimit))) == "studio.upload.error.limit")
    }

    @Test func aRefusalFailsTheJobAndRetryContinues() async throws {
        let studio = RecordingStudio(refuseInitiate: .http(status: 429))
        let queue = UploadQueue(studio: studio, transfer: FixtureTUSTransfer(delay: .zero), store: store())
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 10), title: "Two")])
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .failed)
        #expect(queue.jobs[0].failure == "studio.upload.error.limit")
        queue.resume(queue.jobs[0].id)
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .done)
    }

    @Test func onlyTheActiveAccountsJobsRun() async throws {
        let queue = UploadQueue(studio: RecordingStudio(), transfer: FixtureTUSTransfer(delay: .zero), store: store())
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 10), title: "Other", account: "a2")])
        try await Task.sleep(for: .milliseconds(100))
        #expect(queue.jobs[0].state == .waiting)
        queue.discardJobs(of: "a2")
        #expect(queue.jobs.isEmpty)
    }

    @Test func aRelaunchReloadsTheQueueAndContinues() async throws {
        let shared = store()
        var saved = job(try file(bytes: 10), title: "Three")
        saved.state = .uploading
        saved.ticket = UploadTicket(videoID: "v-Three", tusSessionID: "s", chunkSize: 1 << 20)
        shared.save([saved])
        let studio = RecordingStudio()
        let queue = UploadQueue(studio: studio, transfer: FixtureTUSTransfer(delay: .zero), store: shared)
        #expect(queue.jobs[0].state == .waiting)
        queue.accountID = "a1"
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .done)
        #expect(await studio.calls == ["complete:v-Three:10"])
    }

    // MARK: A transfer that goes quiet (Apple #105)

    @Test func aChunkThatNeverMovesStopsTheJobWithRetryAfterOneAskAgain() async throws {
        let transfer = StallingTransfer(hangingSends: .max)
        let queue = UploadQueue(studio: RecordingStudio(), transfer: transfer, store: store(), stallLimit: .milliseconds(150))
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 10), title: "Stuck")])
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .failed)
        #expect(queue.jobs[0].failure == "studio.upload.error.stalled")
        #expect(transfer.sends == 2, "the chunk is sent, and asked for again once")
        // Retry carries on from where it stopped, with the upload the server already has
        transfer.hangingSends = 0
        queue.resume(queue.jobs[0].id)
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .done)
        #expect(transfer.creates == 1)
    }

    @Test func aStallThatClearsOnTheSecondAskNeverShowsAsAFailure() async throws {
        let transfer = StallingTransfer(hangingSends: 1)
        let queue = UploadQueue(studio: RecordingStudio(), transfer: transfer, store: store(), stallLimit: .milliseconds(150))
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 10), title: "Blip")])
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .done)
        #expect(queue.jobs[0].failure == nil)
        #expect(transfer.sends == 2)
    }

    @Test func aSlowChunkThatKeepsMovingIsNotAStall() async throws {
        let transfer = StallingTransfer(hangingSends: 0, slowSendFor: .milliseconds(500), progressEvery: .milliseconds(30))
        let queue = UploadQueue(studio: RecordingStudio(), transfer: transfer, store: store(), stallLimit: .milliseconds(150))
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 10), title: "Slow")])
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .done)
        #expect(transfer.sends == 1)
    }

    @Test func aCreateThatNeverAnswersStopsTheJobToo() async throws {
        let transfer = StallingTransfer(hangingSends: 0, hangingCreate: true)
        let queue = UploadQueue(studio: RecordingStudio(), transfer: transfer, store: store(), stallLimit: .milliseconds(150))
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 10), title: "NoCreate")])
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .failed)
        #expect(queue.jobs[0].failure == "studio.upload.error.stalled")
        #expect(transfer.sends == 0)
    }

    @Test func aStalledChunkThatLandedContinuesFromTheServersOffsetAndSavesIt() async throws {
        // 2.5 MB is three chunks. The first reaches the server and its answer is lost: the second must start where the
        // server is (1 MiB), not where the queue was, and the saved offset follows.
        let transfer = StallingTransfer(hangingSends: 1, landsBeforeHanging: true)
        let queue = UploadQueue(studio: RecordingStudio(), transfer: transfer, store: store(), stallLimit: .milliseconds(150))
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 2_500_000), title: "Landed")])
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .done)
        #expect(transfer.sentOffsets == [0, 1 << 20, 2 << 20], "no chunk is sent twice and none is skipped")
        #expect(queue.jobs[0].offset == 2_500_000)
    }

    @Test func anOffsetThatStallsTooEndsTheJobWithoutAnotherChunk() async throws {
        let transfer = StallingTransfer(hangingSends: .max)
        transfer.offsetAnswer = .hangs
        let queue = UploadQueue(studio: RecordingStudio(), transfer: transfer, store: store(), stallLimit: .milliseconds(150))
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 10), title: "OffsetStuck")])
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .failed)
        #expect(queue.jobs[0].failure == "studio.upload.error.stalled")
        #expect(transfer.sends == 1, "the chunk is not sent again to a server that does not answer")
    }

    @Test func aSessionThatIsGoneAfterAStallEndsTheJobAndRetryOpensANewOne() async throws {
        let transfer = StallingTransfer(hangingSends: 1)
        transfer.offsetAnswer = .gone
        let queue = UploadQueue(studio: RecordingStudio(), transfer: transfer, store: store(), stallLimit: .milliseconds(150))
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 10), title: "Gone")])
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .failed)
        #expect(transfer.sends == 1)
        transfer.offsetAnswer = .server
        queue.resume(queue.jobs[0].id)
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .done)
    }

    @Test func pausingWhileAChunkIsStalledPausesTheJobInsteadOfFailingIt() async throws {
        let transfer = StallingTransfer(hangingSends: .max)
        let queue = UploadQueue(studio: RecordingStudio(), transfer: transfer, store: store(), stallLimit: .seconds(30))
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 10), title: "Pause")])
        for _ in 0..<200 where transfer.sends == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(transfer.sends == 1)
        queue.pause(queue.jobs[0].id)
        try await waitUntilIdle(queue)
        #expect(queue.jobs[0].state == .paused)
        #expect(queue.jobs[0].failure == nil)
    }

    @Test func switchingAccountStopsTheOldAccountsStalledUploadBeforeItAsksForATokenAgain() async throws {
        let transfer = StallingTransfer(hangingSends: .max)
        let queue = UploadQueue(studio: RecordingStudio(), transfer: transfer, store: store(), stallLimit: .milliseconds(300))
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 10), title: "Mine", account: "a1")])
        for _ in 0..<200 where transfer.sends == 0 { try await Task.sleep(for: .milliseconds(20)) }
        queue.accountID = "a2"
        // Longer than the stall limit and its recovery: nothing of a1's job runs as a2
        try await Task.sleep(for: .milliseconds(900))
        #expect(queue.jobs[0].state == .waiting)
        #expect(queue.jobs[0].failure == nil)
        #expect(transfer.sends == 1, "the chunk is not sent again under the new account")
        queue.accountID = "a1"
        for _ in 0..<50 where transfer.sends < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(transfer.sends >= 2, "back on its own account the job runs again")
        queue.pause(queue.jobs[0].id)
    }

    @Test func theStalledMessageIsAFailureTextInBothLanguages() throws {
        #expect(UploadQueue.failureKey(UploadStalled()) == "studio.upload.error.stalled")
        // The text is in both languages' strings files, and says the upload stopped (the live test looks for it)
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "AUNDesign/Sources/AUNDesign/Resources")
        for language in ["en", "ar"] {
            let text = try String(contentsOf: resources.appending(path: "\(language).lproj/Localizable.strings"), encoding: .utf8)
            let line = try #require(
                text.split(separator: "\n").first { $0.hasPrefix("\"studio.upload.error.stalled\"") }, "\(language)")
            #expect(line.hasSuffix(";"))
        }
    }
}

@MainActor
struct UploadComposerTests {
    @Test func makesOneJobPerFileWithTokensAndClears() throws {
        let composer = UploadComposer()
        let directory = FileManager.default.temporaryDirectory
        for name in ["a.mp4", "b.mp4"] {
            let url = directory.appending(path: "\(UUID().uuidString)-\(name)")
            try Data([1]).write(to: url)
            composer.add([try #require(PickedVideo.make(file: url, ownsFile: false))])
        }
        composer.settings.titlePattern = "Tafsir {{episode}}"
        composer.settings.firstEpisode = 4
        composer.files[1].titleOverride = "Custom"
        composer.tagsText = "fiqh, , salah "
        let jobs = composer.makeJobs(channel: FixtureStudioService.channels[0], accountID: "a1", language: .en)
        #expect(jobs.map(\.title) == ["Tafsir 4", "Custom"])
        #expect(jobs[0].settings.tags == ["fiqh", "salah"])
        #expect(jobs.map(\.index) == [0, 1])
        #expect(jobs[0].orderKey.hasSuffix("-0000"))
        #expect(composer.files.isEmpty)
    }

    @Test func refusesNonVideosAndTooSoonSchedules() throws {
        let text = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try Data([1]).write(to: text)
        #expect(PickedVideo.make(file: text, ownsFile: false) == nil)
        let composer = UploadComposer()
        #expect(composer.problem() == "studio.upload.problem.noFiles")
        let video = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        try Data([1]).write(to: video)
        composer.add([try #require(PickedVideo.make(file: video, ownsFile: false))])
        composer.scheduleEnabled = true
        composer.settings.scheduleAt = Date().addingTimeInterval(60)
        #expect(composer.problem() == "studio.upload.problem.scheduleSoon")
        composer.settings.scheduleAt = Date().addingTimeInterval(3600)
        #expect(composer.problem() == nil)
    }
}

/// The queue never calls these.
extension RecordingStudio {
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

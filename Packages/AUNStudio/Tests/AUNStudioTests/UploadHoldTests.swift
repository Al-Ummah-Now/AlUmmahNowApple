import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

/// Uploads that stand still, or are removed, with their account.
@MainActor
struct UploadHoldTests {
    private func store() -> UploadStore {
        UploadStore(url: FileManager.default.temporaryDirectory.appending(path: "q-\(UUID().uuidString).json"))
    }

    private func file(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func job(_ file: URL, title: String, settings: UploadSettings = UploadSettings(), account: String = "a1")
        -> UploadJob
    {
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return UploadJob(
            batchID: UUID(), index: 0, file: file, ownsFile: true, fileSize: size, mimeType: "video/mp4", title: title,
            settings: settings, channelID: "c1", accountID: account)
    }

    /// An initiate or a schedule that the server may be acting on gets its answer, for a limited time.
    private actor SlowStudio: StudioServicing {
        private(set) var calls: [String] = []
        private let delay: Duration

        init(delay: Duration) { self.delay = delay }

        func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
            calls.append("initiate")
            // Not cancelled under it: the request is at the server.
            let end = ContinuousClock.now + delay
            while ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
            calls.append("initiated")
            return UploadTicket(videoID: "v", tusSessionID: "s", chunkSize: 1 << 20)
        }
        func channels() async throws -> [StudioChannel] { [] }
        func playlists(channelID: String) async throws -> [StudioPlaylist] { [] }
        func resumeUpload(videoID: String, channelID: String) async throws -> UploadTicket { throw CoreError.notFound }
        func completeUpload(videoID: String, fileSize: Int64, channelID: String) async throws { calls.append("complete") }
        func tusEndpoint() async throws -> (url: URL, headers: [String: String]) {
            calls.append("token")
            return (URL(string: "https://fixtures.invalid/api/videos/tus")!, [:])
        }
        func setLanguage(_ language: VideoLanguage, videoID: String, channelID: String) async throws {}
        func addToPlaylists(_ playlistIDs: [String], videoID: String, orderKey: String, channelID: String) async throws {}
        func schedule(videoID: String, at date: Date, timeZone: TimeZone, channelID: String) async throws {}
        func content(channelID: String, query: ContentQuery, cursor: String?) async throws -> ContentPage {
            throw CoreError.notFound
        }
        func contentCounts(channelID: String) async throws -> ContentCounts { throw CoreError.notFound }
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
        func channelStats(channelID: String, period: DateInterval) async throws -> ChannelStats { throw CoreError.notFound }
        func videoStats(videoID: String, period: DateInterval) async throws -> VideoStats { throw CoreError.notFound }
    }

    private func holding(_ studio: SlowStudio) async throws -> UploadQueue {
        let queue = UploadQueue(
            studio: studio, transfer: FixtureTUSTransfer(delay: .zero), store: store(),
            defaults: UserDefaults(suiteName: "hold-\(UUID().uuidString)")!)
        queue.accountID = "a1"
        queue.enqueue([job(try file(bytes: 32), title: "Clip", account: "a1")])
        while await studio.calls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        return queue
    }

    @Test func holdingWaitsForAStepTheServerMayBeActingOnAndGoesNoFurther() async throws {
        let studio = SlowStudio(delay: .milliseconds(200))
        let queue = try await holding(studio)
        try await queue.hold("a1")
        #expect(await studio.calls == ["initiate", "initiated"])
        #expect(queue.jobs.map(\.state) == [.waiting])
        // What it learned is kept, so it never initiates twice.
        #expect(queue.jobs.first?.ticket != nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await studio.calls == ["initiate", "initiated"])
        queue.release("a1")
        while queue.jobs.first?.state != .done { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await studio.calls.contains("complete"))
    }

    @Test func anUploadThatDoesNotStandStillInTimeIsAnErrorAndIsLetGo() async throws {
        let studio = SlowStudio(delay: .milliseconds(500))
        let queue = try await holding(studio)
        await #expect(throws: UploadQueue.NotHeld.self) { try await queue.hold("a1", within: .milliseconds(50)) }
        #expect(queue.heldAccounts.isEmpty)
        while queue.jobs.first?.state != .done { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func anotherWindowIsHeldTooAndCantWriteADeletedAccountsUploadsBack() async throws {
        let shared = store()
        let suite = UserDefaults(suiteName: "windows-\(UUID().uuidString)")!
        let first = UploadQueue(
            studio: SlowStudio(delay: .zero), transfer: FixtureTUSTransfer(delay: .zero), store: shared, defaults: suite)
        let second = UploadQueue(
            studio: SlowStudio(delay: .zero), transfer: FixtureTUSTransfer(delay: .seconds(30)), store: shared, defaults: suite)
        second.accountID = "a1"
        second.enqueue([
            job(try file(bytes: 32), title: "Deleted", account: "a1"), job(try file(bytes: 32), title: "Kept", account: "a2"),
        ])
        while second.jobs.first?.state != .uploading { try await Task.sleep(for: .milliseconds(5)) }
        try await first.hold("a1")
        #expect(second.heldAccounts == ["a1"])
        #expect(second.jobs.first?.state == .waiting)
        try first.purgeJobs(of: "a1")
        #expect(second.jobs.map(\.title) == ["Kept"])
        second.pause(second.jobs[0].id)
        #expect(shared.load().map(\.accountID) == ["a2"])
        second.enqueue([job(try file(bytes: 32), title: "Late", account: "a1")])
        #expect(second.jobs.map(\.title) == ["Kept"])
    }

    private func queue(_ store: UploadStore, _ suite: UserDefaults) -> UploadQueue {
        UploadQueue(
            studio: SlowStudio(delay: .zero), transfer: FixtureTUSTransfer(delay: .zero), store: store, defaults: suite)
    }

    @Test func removingAnAccountKeepsWhatAClosedWindowQueuedForAnother() throws {
        let shared = store()
        let suite = UserDefaults(suiteName: "closed-\(UUID().uuidString)")!
        let first = queue(shared, suite)
        let mine = try file(bytes: 32)
        let theirs = try file(bytes: 32)
        weak var closedWindow: UploadQueue?
        // Drain autoreleased references before checking that this queue is no longer a live peer.
        autoreleasepool {
            let closed = queue(shared, suite)
            closedWindow = closed
            closed.enqueue([job(mine, title: "Deleted", account: "a1"), job(theirs, title: "Kept", account: "a2")])
        }
        try #require(closedWindow == nil)
        #expect(first.jobs.isEmpty)
        try first.purgeJobs(of: "a1")
        #expect(shared.load().map(\.title) == ["Kept"])
        #expect(!FileManager.default.fileExists(atPath: mine.path))
        #expect(FileManager.default.fileExists(atPath: theirs.path))
        // This window goes on with it, so its next save keeps it too.
        #expect(first.jobs.map(\.title) == ["Kept"])
        first.pause(try #require(first.jobs.first?.id))
        #expect(shared.load().map(\.title) == ["Kept"])
        #expect(shared.load().map(\.state) == [.paused])
        try? FileManager.default.removeItem(at: theirs)
    }

    @Test func aSavedQueueThatCantBeReadIsNeverWrittenOver() throws {
        let shared = store()
        let broken = Data("not a queue".utf8)
        try broken.write(to: shared.url)
        let first = queue(shared, UserDefaults(suiteName: "broken-\(UUID().uuidString)")!)
        #expect(throws: CoreError.self) { try first.purgeJobs(of: "a1") }
        #expect(try Data(contentsOf: shared.url) == broken)
        try? FileManager.default.removeItem(at: shared.url)
    }

    @Test func copiesOfAnEarlierStartThatNobodyHasGoWithADeletedAccount() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "copies-\(UUID().uuidString)")
        let shared = UploadStore(url: home.appending(path: "uploads.json"))
        defer { try? FileManager.default.removeItem(at: home) }
        func copy(_ name: String, old: Bool) throws -> URL {
            let folder = shared.copies.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "clip.mp4")
            try Data(repeating: 1, count: 8).write(to: file)
            if old {
                try FileManager.default.setAttributes(
                    [.creationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: folder.path)
            }
            return file
        }
        let queued = try copy("queued", old: true)
        let picked = try copy("picked", old: true)
        let forgotten = try copy("forgotten", old: true)
        let copying = try copy("copying", old: false)
        let form = UploadComposer()
        form.add([try #require(PickedVideo.make(file: picked, ownsFile: true))])
        let first = queue(shared, UserDefaults(suiteName: "copies-\(UUID().uuidString)")!)
        first.enqueue([job(queued, title: "Queued", account: "a2")])
        try first.purgeJobs(of: "a1")
        func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }
        #expect(exists(queued))
        #expect(exists(picked))
        #expect(exists(copying))
        #expect(!exists(forgotten))
        withExtendedLifetime(form) {}
    }
}

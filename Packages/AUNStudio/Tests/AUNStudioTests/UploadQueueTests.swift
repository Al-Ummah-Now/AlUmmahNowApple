import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

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
        composer.settings.titlePattern = "Lesson {{episode}}"
        composer.settings.firstEpisode = 4
        composer.files[1].titleOverride = "Custom"
        composer.tagsText = "fiqh, , salah "
        let jobs = composer.makeJobs(channel: FixtureStudioService.channels[0], accountID: "a1", language: .en)
        #expect(jobs.map(\.title) == ["Lesson 4", "Custom"])
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

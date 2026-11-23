import AUNCoreBridge
import AUNDesign
import Foundation
import XCTest

@testable import AUNPlayer

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

final class OfflineAndListenTests: XCTestCase {
    @MainActor
    func testListenModeGatingSwitchAndQueue() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let listen = ListenModeManager(listenModeEnabled: false, now: { clock.now })
        let entry1 = QueueEntry(
            videoId: "v1",
            playbackItem: PlaybackItem(
                url: URL(string: "https://media.example/pub/v1/r1/master.m3u8")!,
                title: "Surah Al-Kahf"
            ),
            audioURL: URL(string: "https://media.example/pub/v1/r1/audio.m4a")!,
            durationSeconds: 600
        )
        listen.setNowPlaying(entry1)
        listen.setAudioOnly(true)
        XCTAssertFalse(listen.isAudioOnly)

        listen.applyFeatures(UserFeatures(on: [.listenMode]))
        listen.setAudioOnly(true)
        XCTAssertTrue(listen.isAudioOnly)

        let entry2 = QueueEntry(
            videoId: "v2",
            playbackItem: PlaybackItem(
                url: URL(string: "https://media.example/pub/v2/r1/master.m3u8")!,
                title: "Surah Yasin"
            )
        )
        listen.playNext(entry2)
        XCTAssertEqual(listen.advance()?.videoId, "v2")

        listen.setSleepTimer(.minutes(15))
        clock.now = clock.now.addingTimeInterval(15 * 60)
        XCTAssertTrue(listen.tickSleepTimer())
    }

    func testPlainDownloadStoreMultiAccountCapsAndAvailabilitySync() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try OfflineDownloadStore(
            rootURL: dir,
            offlineDownloadsEnabled: false,
            settings: OfflineDownloadSettings(wifiOnly: true, maxStorageBytes: 5_000, maxVideos: 2)
        )

        let src = dir.appendingPathComponent("src.m4a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x42, count: 1_500)
        try payload.write(to: src)

        let req = OfflineDownloadRequest(
            userId: "user-a",
            videoId: "vid-1",
            title: "Tafsir Lesson",
            titleAr: "درس التفسير",
            thumbnailPath: "/local/thumbs/vid-1.jpg",
            quality: .audio
        )

        // Blocked when offlineDownloads switch is OFF
        do {
            _ = try await store.saveFromFile(req, sourceURL: src)
            XCTFail("Expected featureOff error")
        } catch let error as OfflineDownloadError {
            XCTAssertEqual(error, .featureOff)
        }

        await store.applyFeatures(UserFeatures(on: [.offlineDownloads]))

        // Signed / remote thumbnail URL forbidden
        var badThumb = req
        badThumb.thumbnailPath = "https://cdn.example/signed-thumb.jpg?sig=1"
        do {
            _ = try await store.saveFromFile(badThumb, sourceURL: src)
            XCTFail("Expected signedURLForbidden error")
        } catch let error as OfflineDownloadError {
            XCTAssertEqual(error, .signedURLForbidden)
        }

        // Plain file saved and directly playable via local file URL
        let saved = try await store.saveFromFile(req, sourceURL: src)
        XCTAssertTrue(saved.fileName.hasSuffix(".m4a"))
        let fileURL = try await store.localFileURL(userId: "user-a", videoId: "vid-1")
        XCTAssertEqual(try Data(contentsOf: fileURL), payload)
        let asset = try await store.makePlayableAsset(userId: "user-a", videoId: "vid-1")
        XCTAssertEqual(asset.url, fileURL)

        // Multi-account isolation: user-b saving same videoId does not clobber user-a
        var reqB = req
        reqB.userId = "user-b"
        _ = try await store.saveFromFile(reqB, sourceURL: src)
        let userADownloads = await store.playableDownloads(userId: "user-a")
        let userBDownloads = await store.playableDownloads(userId: "user-b")
        XCTAssertEqual(userADownloads.count, 1)
        XCTAssertEqual(userBDownloads.count, 1)

        // Storage budget refusal without silently evicting active downloads
        let bigSrc = dir.appendingPathComponent("big.mp4")
        try Data(repeating: 0x77, count: 4_000).write(to: bigSrc)
        do {
            _ = try await store.saveFromFile(
                OfflineDownloadRequest(userId: "user-a", videoId: "vid-big", title: "Big", quality: .q480p),
                sourceURL: bigSrc
            )
            XCTFail("Expected storageBudgetExceeded")
        } catch let error as OfflineDownloadError {
            XCTAssertEqual(error, .storageBudgetExceeded)
        }
        let afterRefusal = await store.playableDownloads(userId: "user-a")
        XCTAssertEqual(afterRefusal.count, 1)

        // Availability sync removes local copies when video goes private or is deleted
        let deleted = try await store.applyAvailabilitySync([
            AvailabilitySyncDecision(videoId: "vid-1", available: false, reason: "video_private")
        ])
        XCTAssertEqual(deleted, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let userAAfterSync = await store.playableDownloads(userId: "user-a")
        let userBAfterSync = await store.playableDownloads(userId: "user-b")
        XCTAssertTrue(userAAfterSync.isEmpty)
        XCTAssertTrue(userBAfterSync.isEmpty)
    }

    func testCarPlayGatingLocalizationAndSearch() {
        let builder = CarPlayLibraryBuilder()
        let download = OfflineDownloadRecord(
            userId: "u1",
            videoId: "v-dl",
            title: "Surah Al-Mulk",
            titleAr: "سورة الملك",
            channelName: "Recitations",
            thumbnailPath: "/local/thumbs/v-dl.jpg",
            durationSeconds: 300,
            quality: .audio,
            fileName: "u1_v-dl.m4a",
            bytes: 1000,
            downloadedAtMs: 1000,
            lastAccessedAtMs: 1000,
            status: .ready
        )
        let input = CarPlayLibraryInput(downloads: [download])

        // Hidden when listenMode is OFF
        XCTAssertTrue(
            builder.buildTabs(input: input, features: .none, language: .en).isEmpty
        )
        XCTAssertTrue(
            builder.search(
                query: "Mulk",
                downloads: [download],
                onlinePool: [],
                listenModeEnabled: false,
                offlineDownloadsEnabled: true
            ).isEmpty
        )

        // Arabic localized tabs when both switches ON
        let arTabs = builder.buildTabs(
            input: input,
            features: UserFeatures(on: [.listenMode, .offlineDownloads]),
            language: .ar
        )
        XCTAssertEqual(arTabs.count, 4)
        XCTAssertEqual(arTabs[1].tab, .downloads)
        XCTAssertEqual(arTabs[1].items.first?.isOffline, true)
    }
}

import Foundation
import Testing

@testable import AUNPlayer

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@Suite("Epic 14: Offline, Listen Mode & CarPlay")
struct OfflineAndListenTests {
    @MainActor
    @Test func listenModeFeatureGateSleepTimerAndQueue() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let manager = ListenModeManager(listenModeEnabled: false, now: { clock.now })

        // Feature OFF blocks audio-only mode
        manager.setAudioOnly(true)
        #expect(manager.isAudioOnly == false)

        // Turning feature ON enables audio-only mode
        manager.setFeatureEnabled(true)
        manager.setAudioOnly(true)
        #expect(manager.isAudioOnly == true)

        // Timed sleep timer expires on schedule
        manager.setSleepTimer(.minutes(15))
        #expect(manager.sleepTimer.isActive)
        #expect(manager.tickSleepTimer() == false)
        clock.now = clock.now.addingTimeInterval(15 * 60)
        #expect(manager.tickSleepTimer() == true)
        #expect(manager.sleepTimer.isActive == false)

        // End of episode pauses playback
        manager.setSleepTimer(.endOfEpisode)
        #expect(manager.handleEpisodeEnded() == true)
        #expect(manager.sleepTimer.isActive == false)

        // Queue operations
        let url = URL(string: "https://media.alummahnow.net/pub/v1/rev/master.m3u8")!
        let e1 = QueueEntry(videoId: "v1", playbackItem: PlaybackItem(url: url, title: "First"))
        let e2 = QueueEntry(videoId: "v2", playbackItem: PlaybackItem(url: url, title: "Second"))
        let e3 = QueueEntry(videoId: "v3", playbackItem: PlaybackItem(url: url, title: "Third"))

        manager.setNowPlaying(e1)
        manager.addToEnd(e2)
        manager.playNext(e3)
        #expect(manager.queue.map(\.videoId) == ["v1", "v3", "v2"])

        manager.moveQueueItem(from: 2, to: 1)
        #expect(manager.queue.map(\.videoId) == ["v1", "v2", "v3"])

        #expect(manager.advance()?.videoId == "v2")
        manager.clearUpNext()
        #expect(manager.queue.map(\.videoId) == ["v2"])
    }

    @Test func chunkedAESGCMRoundTripAndTamperDetection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aun-apple-cipher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vaultA = InMemoryDownloadKeyVault()
        let vaultB = InMemoryDownloadKeyVault()
        let keyA = try vaultA.symmetricKey()
        let keyB = try vaultB.symmetricKey()

        let plaintext = Data((0..<150_000).map { UInt8(($0 * 29) % 251) })
        let dest = dir.appendingPathComponent("lecture.aun")
        _ = try ChunkedAESGCMCipher.encrypt(key: keyA, videoId: "v1", licenseId: "lic1", plaintext: plaintext, to: dest)
        #expect(try Data(contentsOf: dest) != plaintext)

        let decrypted = try ChunkedAESGCMCipher.decrypt(key: keyA, videoId: "v1", licenseId: "lic1", from: dest)
        #expect(decrypted == plaintext)

        // Wrong key must fail
        #expect(throws: Error.self) {
            _ = try ChunkedAESGCMCipher.decrypt(key: keyB, videoId: "v1", licenseId: "lic1", from: dest)
        }
        // Wrong AAD (videoId mismatch) must fail
        #expect(throws: Error.self) {
            _ = try ChunkedAESGCMCipher.decrypt(key: keyA, videoId: "v2", licenseId: "lic1", from: dest)
        }
        // Single-byte tamper must fail
        var tampered = try Data(contentsOf: dest)
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: dest)
        #expect(throws: Error.self) {
            _ = try ChunkedAESGCMCipher.decrypt(key: keyA, videoId: "v1", licenseId: "lic1", from: dest)
        }
    }

    @Test func downloadStoreEnforcesGatePolicyRefreshRevocationAndWipe() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aun-apple-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try OfflineDownloadStore(
            rootURL: dir,
            keyVault: InMemoryDownloadKeyVault(),
            offlineDownloadsEnabled: false,
            now: { baseDate }
        )

        #expect(
            OfflineDownloadPolicy.canDownload(featureEnabled: false, settings: OfflineDownloadSettings(), isConnected: true, isUnmeteredWifi: true)
                == .blockedFeatureOff
        )
        #expect(
            OfflineDownloadPolicy.canDownload(featureEnabled: true, settings: OfflineDownloadSettings(wifiOnly: true), isConnected: true, isUnmeteredWifi: false)
                == .blockedWifiOnly
        )

        await #expect(throws: OfflineDownloadError.featureOff) {
            try await store.saveEncrypted(
                OfflineDownloadRequest(
                    licenseId: "lic-1",
                    videoId: "v1",
                    title: "Surah Al-Kahf",
                    quality: .audio,
                    expiresAt: baseDate.addingTimeInterval(3600)
                ),
                plaintext: Data("audio".utf8)
            )
        }

        await store.setFeatureEnabled(true)
        let r1 = try await store.saveEncrypted(
            OfflineDownloadRequest(
                licenseId: "lic-1",
                videoId: "v1",
                title: "Surah Al-Kahf",
                titleAr: "سورة الكهف",
                channelName: "Qari",
                quality: .audio,
                expiresAt: baseDate.addingTimeInterval(3600)
            ),
            plaintext: Data("audio-1".utf8)
        )
        let r2 = try await store.saveEncrypted(
            OfflineDownloadRequest(
                licenseId: "lic-2",
                videoId: "v2",
                title: "Seerah",
                quality: .q480p,
                expiresAt: baseDate.addingTimeInterval(3600)
            ),
            plaintext: Data("video-2".utf8)
        )

        #expect(try await store.readDecrypted(licenseId: r1.licenseId) == Data("audio-1".utf8))
        #expect(await store.playableDownloads().count == 2)

        let deleted = try await store.applyLicenseRefresh([
            LicenseRefreshDecision(licenseId: r1.licenseId, status: "active", expiresAt: baseDate.addingTimeInterval(86_400)),
            LicenseRefreshDecision(licenseId: r2.licenseId, status: "revoked", reason: "creator_disabled"),
        ])
        #expect(deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(r2.fileName).path))
        #expect(await store.playableDownloads().map(\.licenseId) == ["lic-1"])

        await store.wipeAll()
        #expect(await store.allDownloads().isEmpty)
    }

    @Test func carPlayLibraryBuilderTabsAndVoiceSearch() {
        let builder = CarPlayLibraryBuilder()
        let dl = OfflineDownloadRecord(
            licenseId: "lic-c",
            videoId: "v-offline",
            title: "Surah Yasin",
            titleAr: "سورة يس",
            channelName: "Reciter",
            durationSeconds: 900,
            quality: .audio,
            fileName: "lic-c.aun",
            bytes: 1024,
            expiresAt: Date().addingTimeInterval(3600),
            downloadedAt: Date(),
            lastAccessedAt: Date(),
            status: .ready
        )
        let online = [CarPlayEntry(videoId: "v-online", title: "Tafsir Juz Amma", titleAr: "تفسير جزء عم", channelName: "Scholar")]

        let input = CarPlayLibraryInput(continueListening: online, downloads: [dl])
        let tabsOff = builder.buildTabs(input: input, offlineDownloadsEnabled: false, isArabic: true)
        #expect(tabsOff.map(\.tab) == [.continueListening, .subscriptions, .recitation])
        #expect(tabsOff[0].title == "متابعة الاستماع")

        let tabsOn = builder.buildTabs(input: input, offlineDownloadsEnabled: true, isArabic: false)
        #expect(tabsOn.map(\.tab) == [.continueListening, .downloads, .subscriptions, .recitation])
        #expect(tabsOn[1].items.map(\.videoId) == ["v-offline"])

        let found = builder.search(query: "يس", downloads: [dl], onlinePool: online, offlineDownloadsEnabled: true)
        #expect(found.map(\.videoId) == ["v-offline"])
    }
}

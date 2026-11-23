import AUNCoreBridge
import AUNDesign
import Foundation
import Testing

@testable import AUNPlayer

private actor RecordingSlotReleaser: LicenseSlotReleaser {
    var released: [String] = []
    var revokedDevices: [String] = []

    func releaseLicense(_ licenseId: String) async -> Bool {
        released.append(licenseId)
        return true
    }

    func revokeDevice(_ deviceId: String) async -> Bool {
        revokedDevices.append(deviceId)
        return true
    }
}

@Suite("Epic 14: Offline, Listen Mode & CarPlay")
struct OfflineAndListenTests {
    @Test("AUNDL01 streaming encrypt, random-access chunked decrypt, binding & truncation detection")
    func aundl01StreamingAndTruncation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vault = InMemoryDownloadKeyVault()
        let key = try vault.symmetricKey()
        let plain = Data((0..<(AunDl01Format.chunkSize + 4096)).map { UInt8($0 & 0xFF) })
        let src = dir.appendingPathComponent("src.m4a")
        let enc = dir.appendingPathComponent("clip.aun")
        try plain.write(to: src)

        _ = try AunDl01StreamWriter.encryptFile(
            key: key,
            source: src,
            destination: enc,
            videoId: "vid-1",
            licenseId: "lic-1"
        )

        let reader = try AunDl01RandomAccessReader(
            key: key,
            url: enc,
            expectedVideoId: "vid-1",
            expectedLicenseId: "lic-1"
        )
        #expect(reader.plainLen == UInt64(plain.count))
        let slice = try reader.readRange(offset: UInt64(AunDl01Format.chunkSize - 50), length: 120)
        #expect(slice == plain[(AunDl01Format.chunkSize - 50)..<(AunDl01Format.chunkSize + 70)])

        // Cross-video and cross-license binding rejection.
        #expect(throws: Error.self) {
            _ = try AunDl01RandomAccessReader(
                key: key,
                url: enc,
                expectedVideoId: "vid-other",
                expectedLicenseId: "lic-1"
            )
        }
        #expect(throws: Error.self) {
            _ = try AunDl01RandomAccessReader(
                key: key,
                url: enc,
                expectedVideoId: "vid-1",
                expectedLicenseId: "lic-other"
            )
        }

        // Exact chunk-boundary truncation must fail immediately on open.
        let raw = try Data(contentsOf: enc)
        let hdrLen = 16 + 2 + "vid-1".utf8.count + 2 + "lic-1".utf8.count
        let truncURL = dir.appendingPathComponent("trunc.aun")
        try raw.prefix(hdrLen + AunDl01Format.chunkStride).write(to: truncURL)
        #expect(throws: Error.self) {
            _ = try AunDl01RandomAccessReader(
                key: key,
                url: truncURL,
                expectedVideoId: "vid-1",
                expectedLicenseId: "lic-1"
            )
        }
    }

    @Test("Store isolates accounts, blocks clock rollback, forbids signed URLs, releases slots & never evicts active items")
    func storeLifecycleAndSecurity() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        final class Clocks: @unchecked Sendable {
            var wallMs: Int64 = 10_000
            var monoMs: Int64 = 1_000
        }
        let clocks = Clocks()
        let releaser = RecordingSlotReleaser()
        let store = try OfflineDownloadStore(
            rootURL: dir,
            keyVault: InMemoryDownloadKeyVault(),
            offlineDownloadsEnabled: false,
            settings: OfflineDownloadSettings(maxStorageBytes: 500),
            wallClockMs: { clocks.wallMs },
            monotonicClockMs: { clocks.monoMs },
            slotReleaser: releaser
        )

        let rawFile = dir.appendingPathComponent("raw.bin")
        try Data(repeating: 7, count: 300).write(to: rawFile)

        // Default-off gate
        await #expect(throws: OfflineDownloadError.featureOff) {
            try await store.saveFromFile(
                OfflineDownloadRequest(
                    userId: "u1",
                    licenseId: "lic-off",
                    videoId: "v1",
                    title: "Off",
                    serverTimeMs: 10_000,
                    expiresAtMs: 20_000
                ),
                sourceURL: rawFile
            )
        }

        await store.applyFeatures(UserFeatures(on: [.offlineDownloads]))

        // Signed URL forbidden
        await #expect(throws: OfflineDownloadError.signedURLForbidden) {
            try await store.saveFromFile(
                OfflineDownloadRequest(
                    userId: "u1",
                    licenseId: "lic-url",
                    videoId: "v1",
                    title: "Bad",
                    thumbnailPath: "https://media.alummahnow.net/priv/tok/thumb.jpg",
                    serverTimeMs: 10_000,
                    expiresAtMs: 20_000
                ),
                sourceURL: rawFile
            )
        }

        // Save for u1; attempting a second download over cap must throw instead of silently evicting u1's item.
        _ = try await store.saveFromFile(
            OfflineDownloadRequest(
                userId: "u1",
                licenseId: "lic-1",
                videoId: "v1",
                title: "Lecture 1",
                serverTimeMs: 10_000,
                expiresAtMs: 20_000
            ),
            sourceURL: rawFile
        )
        await #expect(throws: OfflineDownloadError.storageBudgetExceeded) {
            try await store.saveFromFile(
                OfflineDownloadRequest(
                    userId: "u2",
                    licenseId: "lic-2",
                    videoId: "v1",
                    title: "Lecture 1 u2",
                    serverTimeMs: 10_000,
                    expiresAtMs: 90_000
                ),
                sourceURL: rawFile
            )
        }

        // Roll wall clock back while monotonic advances past u1's expiry -> u1 must NOT be playable!
        clocks.wallMs = 1_000
        clocks.monoMs = 15_000  // server anchor 10_000 + 14_000 = 24_000 > 20_000
        #expect(try await store.playableDownloads(userId: "u1").isEmpty)
        await #expect(throws: OfflineDownloadError.licenseExpiredOrRevoked) {
            _ = try await store.openReader(userId: "u1", videoId: "v1")
        }

        // Removing releases the server slot.
        #expect(try await store.remove(userId: "u1", videoId: "v1"))
        #expect(await releaser.released == ["lic-1"])
    }

    @Test("CarPlay tabs are gated on listenMode, localized via L10n, and search offline downloads")
    func carPlayGatingAndLocalization() {
        let builder = CarPlayLibraryBuilder()
        let dl = OfflineDownloadRecord(
            userId: "u1",
            licenseId: "lic-1",
            videoId: "v-off",
            title: "Surah Al-Kahf",
            titleAr: "سورة الكهف",
            channelName: "Al-Huda",
            thumbnailPath: nil,
            durationSeconds: 1800,
            quality: .audio,
            fileName: "u1_lic-1.aun",
            bytes: 1024,
            expiresAtMs: 99_999,
            downloadedAtMs: 1_000,
            lastAccessedAtMs: 1_000,
            status: .ready
        )
        let input = CarPlayLibraryInput(downloads: [dl])

        // Hidden while listenMode is off
        #expect(builder.buildTabs(input: input, features: .none, language: .en).isEmpty)
        #expect(
            builder.search(
                query: "Kahf",
                downloads: [dl],
                onlinePool: [],
                listenModeEnabled: false,
                offlineDownloadsEnabled: true
            ).isEmpty
        )

        // Arabic localization uses in-app L10n, not Locale.current
        let arTabs = builder.buildTabs(
            input: input,
            features: UserFeatures(on: [.listenMode, .offlineDownloads]),
            language: .ar
        )
        #expect(arTabs.count == 4)
        #expect(arTabs[0].title == L10n(.ar)("carplay.tab.continue"))
        #expect(arTabs[1].title == L10n(.ar)("carplay.tab.downloads"))
        #expect(arTabs[1].items.first?.isOffline == true)
    }

    @Test("ListenModeManager respects /api/me/features, sleep timer, and queue")
    @MainActor
    func listenModeAndSleepTimer() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        let manager = ListenModeManager(listenModeEnabled: false, now: { clock.now })
        manager.setAudioOnly(true)
        #expect(!manager.isAudioOnly)

        manager.applyFeatures(UserFeatures(on: [.listenMode]))
        manager.setAudioOnly(true)
        #expect(manager.isAudioOnly)
        manager.setSleepTimer(.minutes(15))
        clock.now = clock.now.addingTimeInterval(15 * 60)
        #expect(manager.tickSleepTimer())
    }
}

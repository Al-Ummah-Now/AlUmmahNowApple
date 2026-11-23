import AUNCoreBridge
import AVFoundation
import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

public enum OfflineDownloadQuality: String, Codable, Hashable, Sendable, CaseIterable {
    case audio = "audio"
    case q360p = "360p"
    case q480p = "480p"
    case q720p = "720p"
    case q1080p = "1080p"
}

public enum OfflineDownloadStatus: String, Codable, Hashable, Sendable {
    case ready
    case expired
    case revoked
}

/// Local encrypted download record. Never persists signed URLs (artwork is stored as a local path only).
public struct OfflineDownloadRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(userId):\(videoId)" }
    public var userId: String
    public var licenseId: String
    public var videoId: String
    public var title: String
    public var titleAr: String?
    public var channelName: String?
    public var thumbnailPath: String?
    public var durationSeconds: Double?
    public var quality: OfflineDownloadQuality
    public var fileName: String
    public var bytes: Int64
    public var expiresAtMs: Int64
    public var downloadedAtMs: Int64
    public var lastAccessedAtMs: Int64
    public var status: OfflineDownloadStatus

    public func isPlayable(effectiveNowMs: Int64) -> Bool {
        status == .ready && expiresAtMs > effectiveNowMs
    }
}

public struct OfflineDownloadSettings: Codable, Hashable, Sendable {
    public static let defaultMaxStorageBytes: Int64 = 2 * 1024 * 1024 * 1024

    public var wifiOnly: Bool
    public var maxStorageBytes: Int64
    public var defaultQuality: OfflineDownloadQuality
    public var autoDownloadEnabled: Bool

    public init(
        wifiOnly: Bool = true,
        maxStorageBytes: Int64 = defaultMaxStorageBytes,
        defaultQuality: OfflineDownloadQuality = .audio,
        autoDownloadEnabled: Bool = false
    ) {
        self.wifiOnly = wifiOnly
        self.maxStorageBytes = maxStorageBytes
        self.defaultQuality = defaultQuality
        self.autoDownloadEnabled = autoDownloadEnabled
    }
}

public struct LicenseRefreshDecision: Hashable, Sendable {
    public var licenseId: String
    public var status: String
    public var expiresAtMs: Int64?
    public var reason: String?

    public init(licenseId: String, status: String, expiresAtMs: Int64? = nil, reason: String? = nil) {
        self.licenseId = licenseId
        self.status = status
        self.expiresAtMs = expiresAtMs
        self.reason = reason
    }
}

public enum OfflineDownloadError: Error, Equatable, Sendable {
    case featureOff
    case invalidHeader
    case invalidBinding
    case signedURLForbidden
    case truncated
    case invalidKey
    case notFound
    case licenseExpiredOrRevoked
    case storageBudgetExceeded
    case keychainFailure(OSStatus)
}

public enum DownloadTransferAllowance: Equatable, Sendable {
    case allowed
    case blockedFeatureOff
    case blockedOffline
    case blockedWifiOnly
}

public enum OfflineDownloadPolicy {
    public static func canDownload(
        featureEnabled: Bool,
        settings: OfflineDownloadSettings,
        isConnected: Bool,
        isUnmeteredWifi: Bool
    ) -> DownloadTransferAllowance {
        if !featureEnabled { return .blockedFeatureOff }
        if !isConnected { return .blockedOffline }
        if settings.wifiOnly && !isUnmeteredWifi { return .blockedWifiOnly }
        return .allowed
    }
}

/// Releases server download slots (`DELETE /api/v1/downloads/:licenseId` and `revoke-device`).
public protocol LicenseSlotReleaser: Sendable {
    func releaseLicense(_ licenseId: String) async -> Bool
    func revokeDevice(_ deviceId: String) async -> Bool
}

public protocol DownloadKeyVault: Sendable {
    func symmetricKey() throws -> SymmetricKey
}

public final class InMemoryDownloadKeyVault: DownloadKeyVault {
    private let key: SymmetricKey

    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.key = key
    }

    public func symmetricKey() throws -> SymmetricKey { key }
}

/// Device-bound 256-bit AES key stored in Keychain with `ThisDeviceOnly` accessibility (excluded from iCloud).
public final class KeychainDownloadKeyVault: DownloadKeyVault {
    private let service: String
    private let account: String

    public init(service: String = "net.alummahnow.downloads", account: String = "offline-aes256-key") {
        self.service = service
        self.account = account
    }

    public func symmetricKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        if status != errSecItemNotFound {
            throw OfflineDownloadError.keychainFailure(status)
        }
        let fresh = SymmetricKey(size: .bits256)
        let raw = fresh.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OfflineDownloadError.keychainFailure(addStatus)
        }
        return fresh
    }
}

public struct OfflineDownloadRequest: Hashable, Sendable {
    public var userId: String
    public var licenseId: String
    public var videoId: String
    public var title: String
    public var titleAr: String?
    public var channelName: String?
    public var thumbnailPath: String?
    public var durationSeconds: Double?
    public var quality: OfflineDownloadQuality
    public var serverTimeMs: Int64
    public var expiresAtMs: Int64

    public init(
        userId: String = "default",
        licenseId: String,
        videoId: String,
        title: String,
        titleAr: String? = nil,
        channelName: String? = nil,
        thumbnailPath: String? = nil,
        durationSeconds: Double? = nil,
        quality: OfflineDownloadQuality = .audio,
        serverTimeMs: Int64,
        expiresAtMs: Int64
    ) {
        self.userId = userId
        self.licenseId = licenseId
        self.videoId = videoId
        self.title = title
        self.titleAr = titleAr
        self.channelName = channelName
        self.thumbnailPath = thumbnailPath
        self.durationSeconds = durationSeconds
        self.quality = quality
        self.serverTimeMs = serverTimeMs
        self.expiresAtMs = expiresAtMs
    }
}

private struct ManifestEnvelope: Codable {
    var version: Int
    var highWaterNowMs: Int64
    var pendingSlotReleases: [String]
    var items: [OfflineDownloadRecord]
}

/// Encrypted local download vault excluded from iCloud backups (E14-S9):
/// - Uses the shared `AUNDL01` streaming format bound to `(videoId, licenseId)`.
/// - Keys records by `(userId, videoId)` and forbids signed URL persistence.
/// - Evaluates license expiry against `max(wallClock, highWaterNowMs, serverAnchor + monotonicElapsed)`.
/// - Releases server slots on delete/revocation/wipe and never silently evicts active user downloads.
public actor OfflineDownloadStore {
    private let rootURL: URL
    private let manifestURL: URL
    private let keyVault: any DownloadKeyVault
    private let wallClockMs: @Sendable () -> Int64
    private let monotonicClockMs: @Sendable () -> Int64
    private let slotReleaser: (any LicenseSlotReleaser)?
    private let deviceId: String

    public private(set) var offlineDownloadsEnabled: Bool
    public private(set) var settings: OfflineDownloadSettings
    private var records: [String: OfflineDownloadRecord] = [:]
    private var pendingSlotReleases: Set<String> = []
    private var highWaterNowMs: Int64 = 0
    private var serverClockAnchor: (serverMs: Int64, monotonicMs: Int64)?

    public init(
        rootURL: URL,
        keyVault: any DownloadKeyVault,
        offlineDownloadsEnabled: Bool = false,
        settings: OfflineDownloadSettings = OfflineDownloadSettings(),
        wallClockMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        monotonicClockMs: @escaping @Sendable () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
        slotReleaser: (any LicenseSlotReleaser)? = nil,
        deviceId: String = "apple-device"
    ) throws {
        self.rootURL = rootURL
        self.manifestURL = rootURL.appendingPathComponent("manifest.json")
        self.keyVault = keyVault
        self.offlineDownloadsEnabled = offlineDownloadsEnabled
        self.settings = settings
        self.wallClockMs = wallClockMs
        self.monotonicClockMs = monotonicClockMs
        self.slotReleaser = slotReleaser
        self.deviceId = deviceId

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try? mutableRoot.setResourceValues(resourceValues)

        if let data = try? Data(contentsOf: manifestURL),
            let env = try? JSONDecoder().decode(ManifestEnvelope.self, from: data)
        {
            self.highWaterNowMs = env.highWaterNowMs
            self.pendingSlotReleases = Set(env.pendingSlotReleases)
            for rec in env.items {
                let fileURL = rootURL.appendingPathComponent(rec.fileName)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    records["\(rec.userId)\u{1F}\(rec.videoId)"] = rec
                    self.highWaterNowMs = max(self.highWaterNowMs, rec.downloadedAtMs)
                }
            }
        }
    }

    private func recordKey(userId: String, videoId: String) -> String {
        "\(userId)\u{1F}\(videoId)"
    }

    public func setFeatureEnabled(_ enabled: Bool) {
        offlineDownloadsEnabled = enabled
    }

    /// Wires `offlineDownloads` from `GET /api/me/features`.
    public func applyFeatures(_ features: UserFeatures) {
        offlineDownloadsEnabled = features.isOn(.offlineDownloads)
    }

    @discardableResult
    public func observeServerTime(_ serverTimeMs: Int64) throws -> Int64 {
        serverClockAnchor = (serverTimeMs, monotonicClockMs())
        if serverTimeMs > highWaterNowMs {
            highWaterNowMs = serverTimeMs
            try persistManifest()
        }
        return highWaterNowMs
    }

    private func effectiveNowMs() throws -> Int64 {
        var effective = max(wallClockMs(), highWaterNowMs)
        if let anchor = serverClockAnchor {
            let mono = monotonicClockMs()
            if mono >= anchor.monotonicMs {
                effective = max(effective, anchor.serverMs + (mono - anchor.monotonicMs))
            }
        }
        if effective > highWaterNowMs {
            highWaterNowMs = effective
            try persistManifest()
        }
        return effective
    }

    public func updateSettings(_ newSettings: OfflineDownloadSettings) async throws {
        settings = newSettings
        await purgeInactive()
        try persistManifest()
    }

    /// Streams an encrypted download from a downloaded temporary file (`URLSessionDownloadTask`)
    /// into `AUNDL01` at rest. Never holds the full file in RAM and never silently evicts active downloads.
    @discardableResult
    public func saveFromFile(
        _ request: OfflineDownloadRequest,
        sourceURL: URL
    ) async throws -> OfflineDownloadRecord {
        guard offlineDownloadsEnabled else { throw OfflineDownloadError.featureOff }
        if let thumb = request.thumbnailPath,
            thumb.hasPrefix("http://") || thumb.hasPrefix("https://")
        {
            throw OfflineDownloadError.signedURLForbidden
        }
        try observeServerTime(request.serverTimeMs)
        await purgeInactive()

        let used = totalUsedBytes()
        let incomingSize =
            ((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        if settings.maxStorageBytes > 0 && incomingSize > 0 && used + incomingSize > settings.maxStorageBytes {
            throw OfflineDownloadError.storageBudgetExceeded
        }

        let sanitized = "\(request.userId)_\(request.licenseId)".replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
        let safeName = "\(sanitized).aun"
        let dest = rootURL.appendingPathComponent(safeName)
        let key = try keyVault.symmetricKey()
        let encryptedSize = try AunDl01StreamWriter.encryptFile(
            key: key,
            source: sourceURL,
            destination: dest,
            videoId: request.videoId,
            licenseId: request.licenseId
        )
        if settings.maxStorageBytes > 0 && used + encryptedSize > settings.maxStorageBytes {
            try? FileManager.default.removeItem(at: dest)
            throw OfflineDownloadError.storageBudgetExceeded
        }

        let rKey = recordKey(userId: request.userId, videoId: request.videoId)
        if let prev = records[rKey] {
            if prev.fileName != safeName {
                try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(prev.fileName))
            }
            if prev.licenseId != request.licenseId {
                await releaseServerSlot(prev.licenseId)
            }
        }
        let ts = try effectiveNowMs()
        let record = OfflineDownloadRecord(
            userId: request.userId,
            licenseId: request.licenseId,
            videoId: request.videoId,
            title: request.title,
            titleAr: request.titleAr,
            channelName: request.channelName,
            thumbnailPath: request.thumbnailPath,
            durationSeconds: request.durationSeconds,
            quality: request.quality,
            fileName: safeName,
            bytes: encryptedSize,
            expiresAtMs: request.expiresAtMs,
            downloadedAtMs: ts,
            lastAccessedAtMs: ts,
            status: .ready
        )
        records[rKey] = record
        try persistManifest()
        return record
    }

    /// Opens an O(1) random-access chunked reader for playback (no full-file memory buffer).
    public func openReader(userId: String, videoId: String) throws -> AunDl01RandomAccessReader {
        let rKey = recordKey(userId: userId, videoId: videoId)
        guard var rec = records[rKey] else { throw OfflineDownloadError.notFound }
        let ts = try effectiveNowMs()
        guard rec.isPlayable(effectiveNowMs: ts) else { throw OfflineDownloadError.licenseExpiredOrRevoked }
        let key = try keyVault.symmetricKey()
        let reader = try AunDl01RandomAccessReader(
            key: key,
            url: rootURL.appendingPathComponent(rec.fileName),
            expectedVideoId: rec.videoId,
            expectedLicenseId: rec.licenseId
        )
        rec.lastAccessedAtMs = ts
        records[rKey] = rec
        try persistManifest()
        return reader
    }

    /// Creates an `AVURLAsset` paired with its chunked decrypting `AVAssetResourceLoaderDelegate`.
    public func makePlayableAsset(
        userId: String,
        videoId: String,
        queue: DispatchQueue = DispatchQueue(label: "net.alummahnow.offline.loader")
    ) throws -> (asset: AVURLAsset, delegate: AunOfflineAssetResourceLoaderDelegate) {
        let rKey = recordKey(userId: userId, videoId: videoId)
        guard let rec = records[rKey] else { throw OfflineDownloadError.notFound }
        let reader = try openReader(userId: userId, videoId: videoId)
        let delegate = AunOfflineAssetResourceLoaderDelegate(reader: reader, quality: rec.quality)
        let asset = AVURLAsset(url: AunOfflineAssetResourceLoaderDelegate.assetURL(for: videoId))
        asset.resourceLoader.setDelegate(delegate, queue: queue)
        return (asset, delegate)
    }

    public func playableDownloads(userId: String) throws -> [OfflineDownloadRecord] {
        guard offlineDownloadsEnabled else { return [] }
        let ts = try effectiveNowMs()
        return records.values
            .filter { $0.userId == userId && $0.isPlayable(effectiveNowMs: ts) }
            .sorted { $0.downloadedAtMs > $1.downloadedAtMs }
    }

    public func allDownloads(userId: String? = nil) -> [OfflineDownloadRecord] {
        records.values
            .filter { userId == nil || $0.userId == userId }
            .sorted { $0.downloadedAtMs > $1.downloadedAtMs }
    }

    public func totalUsedBytes() -> Int64 {
        records.values.reduce(0) { $0 + $1.bytes }
    }

    public func pendingServerSlotReleases() -> Set<String> {
        pendingSlotReleases
    }

    @discardableResult
    public func remove(userId: String, videoId: String) async throws -> Bool {
        let rKey = recordKey(userId: userId, videoId: videoId)
        guard let removed = records.removeValue(forKey: rKey) else { return false }
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(removed.fileName))
        await releaseServerSlot(removed.licenseId)
        try persistManifest()
        return true
    }

    @discardableResult
    public func applyLicenseRefresh(_ decisions: [LicenseRefreshDecision], serverTimeMs: Int64) async throws -> Int {
        try observeServerTime(serverTimeMs)
        var deleted = 0
        for d in decisions {
            guard let (rKey, existing) = records.first(where: { $0.value.licenseId == d.licenseId }) else { continue }
            if d.status == "active", let newExpiry = d.expiresAtMs {
                var updated = existing
                updated.expiresAtMs = newExpiry
                updated.status = .ready
                records[rKey] = updated
            } else {
                records.removeValue(forKey: rKey)
                try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(existing.fileName))
                await releaseServerSlot(existing.licenseId)
                deleted += 1
            }
        }
        _ = await flushPendingSlotReleases()
        try persistManifest()
        return deleted
    }

    @discardableResult
    public func flushPendingSlotReleases() async -> Int {
        guard let releaser = slotReleaser else { return 0 }
        var flushed = 0
        for id in Array(pendingSlotReleases) {
            let ok = await releaser.releaseLicense(id)
            if ok {
                pendingSlotReleases.remove(id)
                flushed += 1
            }
        }
        if flushed > 0 { try? persistManifest() }
        return flushed
    }

    @discardableResult
    public func clearForUser(_ userId: String) async throws -> Int {
        let keys = records.filter { $0.value.userId == userId }.map(\.key)
        for k in keys {
            if let rec = records.removeValue(forKey: k) {
                try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(rec.fileName))
                await releaseServerSlot(rec.licenseId)
            }
        }
        _ = await slotReleaser?.revokeDevice(deviceId)
        try persistManifest()
        return keys.count
    }

    public func wipeAll() async {
        for rec in records.values {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(rec.fileName))
            await releaseServerSlot(rec.licenseId)
        }
        records.removeAll()
        _ = await slotReleaser?.revokeDevice(deviceId)
        if pendingSlotReleases.isEmpty {
            try? FileManager.default.removeItem(at: manifestURL)
        } else {
            try? persistManifest()
        }
    }

    private func releaseServerSlot(_ licenseId: String) async {
        guard let releaser = slotReleaser else { return }
        if !(await releaser.releaseLicense(licenseId)) {
            pendingSlotReleases.insert(licenseId)
        }
    }

    private func purgeInactive() async {
        let ts = (try? effectiveNowMs()) ?? highWaterNowMs
        let inactive = records.filter { !$0.value.isPlayable(effectiveNowMs: ts) }.map(\.key)
        for k in inactive {
            if let rec = records.removeValue(forKey: k) {
                try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(rec.fileName))
                await releaseServerSlot(rec.licenseId)
            }
        }
    }

    private func persistManifest() throws {
        let env = ManifestEnvelope(
            version: 2,
            highWaterNowMs: highWaterNowMs,
            pendingSlotReleases: Array(pendingSlotReleases).sorted(),
            items: Array(records.values)
        )
        let data = try JSONEncoder().encode(env)
        try data.write(to: manifestURL, options: [.atomic])
    }
}

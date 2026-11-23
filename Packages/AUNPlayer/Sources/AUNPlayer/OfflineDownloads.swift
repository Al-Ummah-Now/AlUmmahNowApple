import CryptoKit
import Foundation
import Security

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

public struct OfflineDownloadRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { licenseId }
    public var licenseId: String
    public var videoId: String
    public var title: String
    public var titleAr: String?
    public var channelName: String?
    public var durationSeconds: Double?
    public var quality: OfflineDownloadQuality
    public var fileName: String
    public var bytes: Int64
    public var expiresAt: Date
    public var downloadedAt: Date
    public var lastAccessedAt: Date
    public var status: OfflineDownloadStatus

    public func isPlayable(at now: Date) -> Bool {
        status == .ready && expiresAt > now
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
    public var expiresAt: Date?
    public var reason: String?

    public init(licenseId: String, status: String, expiresAt: Date? = nil, reason: String? = nil) {
        self.licenseId = licenseId
        self.status = status
        self.expiresAt = expiresAt
        self.reason = reason
    }
}

public enum OfflineDownloadError: Error, Equatable, Sendable {
    case featureOff
    case invalidHeader
    case truncated
    case invalidKey
    case notFound
    case licenseExpiredOrRevoked
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

/// Chunked AES-256-GCM encryption at rest (64 KiB chunks, random 12-byte nonces, per-chunk AAD binding).
public enum ChunkedAESGCMCipher {
    private static let magic = Data("AUN1".utf8)
    private static let chunkBytes = 64 * 1024

    public static func encrypt(
        key: SymmetricKey,
        videoId: String,
        licenseId: String,
        plaintext: Data,
        to destination: URL
    ) throws -> Int64 {
        var out = Data()
        out.append(magic)
        var offset = 0
        var chunkIndex = 0
        repeat {
            let end = min(plaintext.count, offset + chunkBytes)
            let slice = plaintext.subdata(in: offset..<end)
            let nonce = AES.GCM.Nonce()
            let aad = Data("\(videoId)|\(licenseId)|\(chunkIndex)".utf8)
            let sealed = try AES.GCM.seal(slice, using: key, nonce: nonce, authenticating: aad)
            let combined = sealed.ciphertext + sealed.tag
            var lenBE = UInt32(combined.count).bigEndian
            withUnsafeBytes(of: &lenBE) { out.append(contentsOf: $0) }
            out.append(contentsOf: nonce)
            out.append(combined)
            offset = end
            chunkIndex += 1
        } while offset < plaintext.count

        try out.write(to: destination, options: [.atomic])
        return Int64(out.count)
    }

    public static func decrypt(
        key: SymmetricKey,
        videoId: String,
        licenseId: String,
        from source: URL
    ) throws -> Data {
        let data = try Data(contentsOf: source)
        guard data.count >= magic.count, data.prefix(magic.count) == magic else {
            throw OfflineDownloadError.invalidHeader
        }
        var out = Data()
        var cursor = magic.count
        var chunkIndex = 0
        while cursor < data.count {
            guard cursor + 4 + 12 <= data.count else { throw OfflineDownloadError.truncated }
            var lenBE: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &lenBE) { dst in
                data.copyBytes(to: dst, from: cursor..<(cursor + 4))
            }
            let combinedLen = Int(UInt32(bigEndian: lenBE))
            cursor += 4
            guard combinedLen >= 16, cursor + 12 + combinedLen <= data.count else {
                throw OfflineDownloadError.truncated
            }
            let nonceData = data.subdata(in: cursor..<(cursor + 12))
            cursor += 12
            let ciphertextLen = combinedLen - 16
            let ciphertext = data.subdata(in: cursor..<(cursor + ciphertextLen))
            let tag = data.subdata(in: (cursor + ciphertextLen)..<(cursor + combinedLen))
            cursor += combinedLen

            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let aad = Data("\(videoId)|\(licenseId)|\(chunkIndex)".utf8)
            let plain = try AES.GCM.open(box, using: key, authenticating: aad)
            out.append(plain)
            chunkIndex += 1
        }
        return out
    }
}

/// Encrypted local download vault excluded from iCloud backups (E14-S9).
public actor OfflineDownloadStore {
    private let rootURL: URL
    private let manifestURL: URL
    private let keyVault: any DownloadKeyVault
    private let now: @Sendable () -> Date

    public private(set) var offlineDownloadsEnabled: Bool
    public private(set) var settings: OfflineDownloadSettings
    private var records: [String: OfflineDownloadRecord] = [:]

    public init(
        rootURL: URL,
        keyVault: any DownloadKeyVault,
        offlineDownloadsEnabled: Bool = false,
        settings: OfflineDownloadSettings = OfflineDownloadSettings(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.rootURL = rootURL
        self.manifestURL = rootURL.appendingPathComponent("manifest.json")
        self.keyVault = keyVault
        self.offlineDownloadsEnabled = offlineDownloadsEnabled
        self.settings = settings
        self.now = now

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try? mutableRoot.setResourceValues(resourceValues)

        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode([OfflineDownloadRecord].self, from: data) {
            for rec in decoded {
                let fileURL = rootURL.appendingPathComponent(rec.fileName)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    records[rec.licenseId] = rec
                }
            }
        }
    }

    public func setFeatureEnabled(_ enabled: Bool) {
        offlineDownloadsEnabled = enabled
    }

    public func updateSettings(_ newSettings: OfflineDownloadSettings) throws {
        settings = newSettings
        evictToCap()
        try persistManifest()
    }

    @discardableResult
    public func saveEncrypted(
        licenseId: String,
        videoId: String,
        title: String,
        titleAr: String? = nil,
        channelName: String? = nil,
        durationSeconds: Double? = nil,
        quality: OfflineDownloadQuality,
        expiresAt: Date,
        plaintext: Data
    ) throws -> OfflineDownloadRecord {
        guard offlineDownloadsEnabled else { throw OfflineDownloadError.featureOff }
        let safeName = licenseId.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression) + ".aun"
        let dest = rootURL.appendingPathComponent(safeName)
        let key = try keyVault.symmetricKey()
        let encryptedSize = try ChunkedAESGCMCipher.encrypt(
            key: key,
            videoId: videoId,
            licenseId: licenseId,
            plaintext: plaintext,
            to: dest
        )
        let ts = now()
        let record = OfflineDownloadRecord(
            licenseId: licenseId,
            videoId: videoId,
            title: title,
            titleAr: titleAr,
            channelName: channelName,
            durationSeconds: durationSeconds,
            quality: quality,
            fileName: safeName,
            bytes: encryptedSize,
            expiresAt: expiresAt,
            downloadedAt: ts,
            lastAccessedAt: ts,
            status: .ready
        )
        records[licenseId] = record
        evictToCap()
        try persistManifest()
        return record
    }

    public func readDecrypted(licenseId: String) throws -> Data {
        guard var rec = records[licenseId] else { throw OfflineDownloadError.notFound }
        let ts = now()
        guard rec.isPlayable(at: ts) else { throw OfflineDownloadError.licenseExpiredOrRevoked }
        let key = try keyVault.symmetricKey()
        let plain = try ChunkedAESGCMCipher.decrypt(
            key: key,
            videoId: rec.videoId,
            licenseId: rec.licenseId,
            from: rootURL.appendingPathComponent(rec.fileName)
        )
        rec.lastAccessedAt = ts
        records[licenseId] = rec
        try persistManifest()
        return plain
    }

    public func playableDownloads() -> [OfflineDownloadRecord] {
        guard offlineDownloadsEnabled else { return [] }
        let ts = now()
        return records.values
            .filter { $0.isPlayable(at: ts) }
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }

    public func allDownloads() -> [OfflineDownloadRecord] {
        records.values.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    public func totalUsedBytes() -> Int64 {
        records.values.reduce(0) { $0 + $1.bytes }
    }

    @discardableResult
    public func remove(licenseId: String) throws -> Bool {
        guard let removed = records.removeValue(forKey: licenseId) else { return false }
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(removed.fileName))
        try persistManifest()
        return true
    }

    /// Applies batch refresh decisions from `POST /api/v1/downloads/refresh`; deletes revoked/expired files immediately.
    @discardableResult
    public func applyLicenseRefresh(_ decisions: [LicenseRefreshDecision]) throws -> Int {
        var deleted = 0
        for d in decisions {
            guard var existing = records[d.licenseId] else { continue }
            if d.status == "active", let newExpiry = d.expiresAt {
                existing.expiresAt = newExpiry
                existing.status = .ready
                records[d.licenseId] = existing
            } else {
                records.removeValue(forKey: d.licenseId)
                try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(existing.fileName))
                deleted += 1
            }
        }
        try persistManifest()
        return deleted
    }

    /// Wipes every local encrypted download and manifest on sign-out or account deletion.
    public func wipeAll() {
        for rec in records.values {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(rec.fileName))
        }
        records.removeAll()
        try? FileManager.default.removeItem(at: manifestURL)
    }

    private func evictToCap() {
        let cap = settings.maxStorageBytes
        guard cap > 0 else { return }
        var used = totalUsedBytes()
        guard used > cap else { return }
        let byLRU = records.values.sorted { $0.lastAccessedAt < $1.lastAccessedAt }
        for victim in byLRU {
            guard used > cap else { break }
            records.removeValue(forKey: victim.licenseId)
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(victim.fileName))
            used -= victim.bytes
        }
    }

    private func persistManifest() throws {
        let data = try JSONEncoder().encode(Array(records.values))
        try data.write(to: manifestURL, options: [.atomic])
    }
}

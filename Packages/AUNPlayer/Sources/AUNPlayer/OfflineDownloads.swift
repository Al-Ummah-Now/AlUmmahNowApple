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

/// Shared `AUNDL01` chunked AES-256-GCM binary format matching `AlUmmahNowCore` (`crates/aun-downloads`):
/// - Header: `MAGIC("AUNDL01\0")` (8 B) + base nonce (8 B) + `u16 BE videoIdLen` + `videoId`
///   + `u16 BE licenseIdLen` + `licenseId`
/// - Fixed 64 KiB plaintext chunks + 16 B GCM tag (`65552` B stride), `is_final` flag in AAD.
/// - Opening `AunDl01RandomAccessReader` authenticates the final chunk immediately so truncated or
///   cross-license files fail on open.
public enum AunDl01Format {
    public static let magic = Data([0x41, 0x55, 0x4E, 0x44, 0x4C, 0x30, 0x31, 0x00])
    public static let chunkSize = 64 * 1024
    public static let tagLen = 16
    public static let chunkStride = chunkSize + tagLen
    public static let baseNonceLen = 8
    private static let maxIdLen = 512

    static func validateBinding(videoId: String, licenseId: String) throws {
        let vidCount = videoId.utf8.count
        let licCount = licenseId.utf8.count
        guard vidCount > 0, vidCount <= maxIdLen, licCount > 0, licCount <= maxIdLen else {
            throw OfflineDownloadError.invalidBinding
        }
    }

    static func chunkNonce(prefix: Data, index: UInt32) throws -> AES.GCM.Nonce {
        var raw = Data(capacity: 12)
        raw.append(prefix)
        var be = index.bigEndian
        withUnsafeBytes(of: &be) { raw.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: raw)
    }

    static func buildAAD(videoId: String, licenseId: String, index: UInt32, isFinal: Bool) -> Data {
        let vid = Data(videoId.utf8)
        let lic = Data(licenseId.utf8)
        var aad = Data(capacity: magic.count + 2 + vid.count + 2 + lic.count + 4 + 1)
        aad.append(magic)
        var vidLen = UInt16(vid.count).bigEndian
        withUnsafeBytes(of: &vidLen) { aad.append(contentsOf: $0) }
        aad.append(vid)
        var licLen = UInt16(lic.count).bigEndian
        withUnsafeBytes(of: &licLen) { aad.append(contentsOf: $0) }
        aad.append(lic)
        var idxBE = index.bigEndian
        withUnsafeBytes(of: &idxBE) { aad.append(contentsOf: $0) }
        aad.append(isFinal ? 1 : 0)
        return aad
    }
}

/// Streaming single-pass `AUNDL01` encryptor holding at most ~64 KiB of plaintext in RAM.
public final class AunDl01StreamWriter {
    private let key: SymmetricKey
    private let prefix: Data
    private let videoId: String
    private let licenseId: String
    private let tmpURL: URL
    private let destURL: URL
    private var handle: FileHandle?
    private var pending = Data()
    private var chunkIndex: UInt32 = 0
    private var finished = false

    public init(key: SymmetricKey, destination: URL, videoId: String, licenseId: String) throws {
        try AunDl01Format.validateBinding(videoId: videoId, licenseId: licenseId)
        self.key = key
        self.videoId = videoId
        self.licenseId = licenseId
        self.destURL = destination
        self.tmpURL = destination.appendingPathExtension("aun.tmp")

        var nonceBytes = [UInt8](repeating: 0, count: AunDl01Format.baseNonceLen)
        let rngStatus = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard rngStatus == errSecSuccess else { throw OfflineDownloadError.invalidKey }
        self.prefix = Data(nonceBytes)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmpURL)
        self.handle = fh

        let vid = Data(videoId.utf8)
        let lic = Data(licenseId.utf8)
        var hdr = Data(capacity: 16 + 2 + vid.count + 2 + lic.count)
        hdr.append(AunDl01Format.magic)
        hdr.append(prefix)
        var vidLen = UInt16(vid.count).bigEndian
        withUnsafeBytes(of: &vidLen) { hdr.append(contentsOf: $0) }
        hdr.append(vid)
        var licLen = UInt16(lic.count).bigEndian
        withUnsafeBytes(of: &licLen) { hdr.append(contentsOf: $0) }
        hdr.append(lic)
        try fh.write(contentsOf: hdr)
    }

    deinit {
        if !finished {
            try? handle?.close()
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }

    public func write(_ chunk: Data) throws {
        guard !finished, let fh = handle else { throw OfflineDownloadError.truncated }
        pending.append(chunk)
        while pending.count > AunDl01Format.chunkSize {
            let slice = pending.prefix(AunDl01Format.chunkSize)
            pending.removeFirst(AunDl01Format.chunkSize)
            let nonce = try AunDl01Format.chunkNonce(prefix: prefix, index: chunkIndex)
            let aad = AunDl01Format.buildAAD(
                videoId: videoId,
                licenseId: licenseId,
                index: chunkIndex,
                isFinal: false
            )
            let sealed = try AES.GCM.seal(slice, using: key, nonce: nonce, authenticating: aad)
            try fh.write(contentsOf: sealed.ciphertext)
            try fh.write(contentsOf: sealed.tag)
            chunkIndex += 1
        }
    }

    @discardableResult
    public func finish() throws -> Int64 {
        guard !finished, let fh = handle else { throw OfflineDownloadError.truncated }
        let nonce = try AunDl01Format.chunkNonce(prefix: prefix, index: chunkIndex)
        let aad = AunDl01Format.buildAAD(
            videoId: videoId,
            licenseId: licenseId,
            index: chunkIndex,
            isFinal: true
        )
        let sealed = try AES.GCM.seal(pending, using: key, nonce: nonce, authenticating: aad)
        try fh.write(contentsOf: sealed.ciphertext)
        try fh.write(contentsOf: sealed.tag)
        try fh.synchronize()
        try fh.close()
        handle = nil
        pending.removeAll(keepingCapacity: false)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: destURL)
        finished = true
        let attrs = try FileManager.default.attributesOfItem(atPath: destURL.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    public static func encryptFile(
        key: SymmetricKey,
        source: URL,
        destination: URL,
        videoId: String,
        licenseId: String
    ) throws -> Int64 {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try AunDl01StreamWriter(
            key: key,
            destination: destination,
            videoId: videoId,
            licenseId: licenseId
        )
        while let data = try reader.read(upToCount: AunDl01Format.chunkSize), !data.isEmpty {
            try writer.write(data)
        }
        return try writer.finish()
    }
}

/// O(1) random-access chunked AES-256-GCM decrypt-on-read reader for `AUNDL01` files.
/// Never loads the whole file into memory and never writes plaintext to disk.
public final class AunDl01RandomAccessReader: @unchecked Sendable {
    private let key: SymmetricKey
    private let handle: FileHandle
    private let prefix: Data
    public let videoId: String
    public let licenseId: String
    private let dataOffset: UInt64
    public let plainLen: UInt64
    private let numChunks: UInt32
    private let lock = NSLock()
    private var cachedIndex: UInt32?
    private var cachedChunk = Data()

    public init(
        key: SymmetricKey,
        url: URL,
        expectedVideoId: String,
        expectedLicenseId: String
    ) throws {
        try AunDl01Format.validateBinding(videoId: expectedVideoId, licenseId: expectedLicenseId)
        let fh = try FileHandle(forReadingFrom: url)
        do {
            let fileLen = try fh.seekToEnd()
            try fh.seek(toOffset: 0)
            guard fileLen >= 16, let fixed = try fh.read(upToCount: 16), fixed.count == 16 else {
                throw OfflineDownloadError.invalidHeader
            }
            guard fixed.prefix(8) == AunDl01Format.magic else {
                throw OfflineDownloadError.invalidHeader
            }
            let prefix = Data(fixed.dropFirst(8))

            func readU16String() throws -> String {
                guard let lenData = try fh.read(upToCount: 2), lenData.count == 2 else {
                    throw OfflineDownloadError.truncated
                }
                let count = Int(UInt16(lenData[0]) << 8 | UInt16(lenData[1]))
                guard count > 0, count <= 512,
                    let bytes = try fh.read(upToCount: count), bytes.count == count,
                    let str = String(data: bytes, encoding: .utf8)
                else {
                    throw OfflineDownloadError.invalidHeader
                }
                return str
            }

            let headerVideoId = try readU16String()
            let headerLicenseId = try readU16String()
            guard headerVideoId == expectedVideoId, headerLicenseId == expectedLicenseId else {
                throw OfflineDownloadError.invalidBinding
            }
            let dataOffset = try fh.offset()
            guard fileLen >= dataOffset + UInt64(AunDl01Format.tagLen) else {
                throw OfflineDownloadError.truncated
            }
            let payloadLen = fileLen - dataOffset
            let stride = UInt64(AunDl01Format.chunkStride)
            let numChunks64 = ((payloadLen - 1) / stride) + 1
            let lastFrameLen = payloadLen - (numChunks64 - 1) * stride
            guard lastFrameLen >= UInt64(AunDl01Format.tagLen), lastFrameLen <= stride else {
                throw OfflineDownloadError.truncated
            }
            if numChunks64 > 1 && lastFrameLen == UInt64(AunDl01Format.tagLen) {
                throw OfflineDownloadError.truncated
            }
            let plainLen =
                (numChunks64 - 1) * UInt64(AunDl01Format.chunkSize)
                + (lastFrameLen - UInt64(AunDl01Format.tagLen))

            self.key = key
            self.handle = fh
            self.prefix = prefix
            self.videoId = headerVideoId
            self.licenseId = headerLicenseId
            self.dataOffset = dataOffset
            self.plainLen = plainLen
            self.numChunks = UInt32(numChunks64)

            // Immediately authenticate the final chunk so truncation/wrong key fails on open.
            _ = try loadChunkLocked(self.numChunks - 1)
        } catch {
            try? fh.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    public func readRange(offset: UInt64, length: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard offset < plainLen, length > 0 else { return Data() }
        let toRead = Int(min(UInt64(length), plainLen - offset))
        var out = Data(capacity: toRead)
        var pos = offset
        var remaining = toRead
        while remaining > 0 {
            let idx = UInt32(pos / UInt64(AunDl01Format.chunkSize))
            let inChunk = Int(pos % UInt64(AunDl01Format.chunkSize))
            let chunk = try loadChunkLocked(idx)
            let take = min(chunk.count - inChunk, remaining)
            out.append(chunk[inChunk..<(inChunk + take)])
            pos += UInt64(take)
            remaining -= take
        }
        return out
    }

    private func loadChunkLocked(_ index: UInt32) throws -> Data {
        if cachedIndex == index { return cachedChunk }
        guard index < numChunks else { throw OfflineDownloadError.truncated }
        let isFinal = index == numChunks - 1
        let chunkPlainLen: Int
        if isFinal {
            chunkPlainLen = Int(plainLen - UInt64(index) * UInt64(AunDl01Format.chunkSize))
        } else {
            chunkPlainLen = AunDl01Format.chunkSize
        }
        let frameLen = chunkPlainLen + AunDl01Format.tagLen
        let fileOffset = dataOffset + UInt64(index) * UInt64(AunDl01Format.chunkStride)
        try handle.seek(toOffset: fileOffset)
        guard let frame = try handle.read(upToCount: frameLen), frame.count == frameLen else {
            throw OfflineDownloadError.truncated
        }
        let ciphertext = frame.prefix(chunkPlainLen)
        let tag = frame.suffix(AunDl01Format.tagLen)
        let nonce = try AunDl01Format.chunkNonce(prefix: prefix, index: index)
        let aad = AunDl01Format.buildAAD(
            videoId: videoId,
            licenseId: licenseId,
            index: index,
            isFinal: isFinal
        )
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plain = try AES.GCM.open(box, using: key, authenticating: aad)
        cachedChunk = plain
        cachedIndex = index
        return cachedChunk
    }
}

/// `AVAssetResourceLoaderDelegate` serving `aun-offline://<videoId>` via 64 KiB on-demand chunk
/// decryption from `AunDl01RandomAccessReader` — zero plaintext temp files, zero whole-file RAM.
public final class AunOfflineAssetResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public static let scheme = "aun-offline"

    private let reader: AunDl01RandomAccessReader
    private let contentType: String

    public init(reader: AunDl01RandomAccessReader, quality: OfflineDownloadQuality) {
        self.reader = reader
        self.contentType = quality == .audio ? UTType.mpeg4Audio.identifier : UTType.mpeg4Movie.identifier
    }

    public static func assetURL(for videoId: String) -> URL {
        URL(string: "\(scheme)://\(videoId)")!
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(reader.plainLen)
            info.isByteRangeAccessSupported = true
        }
        if let dataReq = loadingRequest.dataRequest {
            let start = UInt64(max(0, dataReq.currentOffset))
            let want =
                dataReq.requestsAllDataToEndOfResource
                ? Int(reader.plainLen - min(start, reader.plainLen))
                : dataReq.requestedLength
            var pos = start
            var remaining = want
            do {
                while remaining > 0 {
                    let step = min(remaining, AunDl01Format.chunkSize)
                    let chunk = try reader.readRange(offset: pos, length: step)
                    if chunk.isEmpty { break }
                    dataReq.respond(with: chunk)
                    pos += UInt64(chunk.count)
                    remaining -= chunk.count
                }
            } catch {
                loadingRequest.finishLoading(with: error)
                return true
            }
        }
        loadingRequest.finishLoading()
        return true
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
            if await releaser.releaseLicense(id) {
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

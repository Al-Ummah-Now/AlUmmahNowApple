import AUNCoreBridge
import AVFoundation
import Foundation

public enum OfflineDownloadQuality: String, Codable, Hashable, Sendable, CaseIterable {
    case audio = "audio"
    case q360p = "360p"
    case q480p = "480p"
    case q720p = "720p"
    case q1080p = "1080p"
}

public enum OfflineDownloadStatus: String, Codable, Hashable, Sendable {
    case ready
    case removed
}

/// Plain-file local offline download record (E14-D1: no encryption, no DRM, no license expiry).
/// Never persists signed URLs (neither media URLs nor signed thumbnail URLs); artwork is stored
/// as a local file path in `thumbnailPath`.
public struct OfflineDownloadRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(userId):\(videoId)" }
    public var userId: String
    public var videoId: String
    public var title: String
    public var titleAr: String?
    public var channelName: String?
    public var thumbnailPath: String?
    public var durationSeconds: Double?
    public var quality: OfflineDownloadQuality
    public var fileName: String
    public var bytes: Int64
    public var downloadedAtMs: Int64
    public var lastAccessedAtMs: Int64
    public var status: OfflineDownloadStatus

    public var isPlayable: Bool {
        status == .ready
    }
}

public struct OfflineDownloadSettings: Codable, Hashable, Sendable {
    public static let defaultMaxStorageBytes: Int64 = 2 * 1024 * 1024 * 1024

    public var wifiOnly: Bool
    public var maxStorageBytes: Int64
    public var maxVideos: Int?
    public var defaultQuality: OfflineDownloadQuality
    public var autoDownloadEnabled: Bool

    public init(
        wifiOnly: Bool = true,
        maxStorageBytes: Int64 = defaultMaxStorageBytes,
        maxVideos: Int? = nil,
        defaultQuality: OfflineDownloadQuality = .audio,
        autoDownloadEnabled: Bool = false
    ) {
        self.wifiOnly = wifiOnly
        self.maxStorageBytes = maxStorageBytes
        self.maxVideos = maxVideos
        self.defaultQuality = defaultQuality
        self.autoDownloadEnabled = autoDownloadEnabled
    }
}

/// Server answer for one item in `POST /api/v1/downloads/sync` (hygiene cleanup for deleted/private/disabled videos).
public struct AvailabilitySyncDecision: Hashable, Sendable {
    public var videoId: String
    public var available: Bool
    public var reason: String?

    public init(videoId: String, available: Bool, reason: String? = nil) {
        self.videoId = videoId
        self.available = available
        self.reason = reason
    }
}

public enum OfflineDownloadError: Error, Equatable, Sendable {
    case featureOff
    case signedURLForbidden
    case notFound
    case storageBudgetExceeded
    case maxVideosExceeded
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

public struct OfflineDownloadRequest: Hashable, Sendable {
    public var userId: String
    public var videoId: String
    public var title: String
    public var titleAr: String?
    public var channelName: String?
    public var thumbnailPath: String?
    public var durationSeconds: Double?
    public var quality: OfflineDownloadQuality

    public init(
        userId: String = "default",
        videoId: String,
        title: String,
        titleAr: String? = nil,
        channelName: String? = nil,
        thumbnailPath: String? = nil,
        durationSeconds: Double? = nil,
        quality: OfflineDownloadQuality = .audio
    ) {
        self.userId = userId
        self.videoId = videoId
        self.title = title
        self.titleAr = titleAr
        self.channelName = channelName
        self.thumbnailPath = thumbnailPath
        self.durationSeconds = durationSeconds
        self.quality = quality
    }
}

private struct ManifestEnvelope: Codable {
    var version: Int
    var items: [OfflineDownloadRecord]
}

/// Plain-file local download store excluded from iCloud backups (E14-S9, E14-D1):
/// - Stores plain progressive `audio.m4a` / `video.mp4` files played directly by `AVPlayer`.
/// - Keys records by `(userId, videoId)` and forbids persisting signed URLs.
/// - Enforces local storage budget and tier video count caps without silently evicting active downloads.
/// - Deletes local copies during availability sync when videos go private, are deleted, or are disabled.
public actor OfflineDownloadStore {
    private let rootURL: URL
    private let manifestURL: URL
    private let clockMs: @Sendable () -> Int64

    public private(set) var offlineDownloadsEnabled: Bool
    public private(set) var settings: OfflineDownloadSettings
    private var records: [String: OfflineDownloadRecord] = [:]

    public init(
        rootURL: URL,
        offlineDownloadsEnabled: Bool = false,
        settings: OfflineDownloadSettings = OfflineDownloadSettings(),
        clockMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) throws {
        self.rootURL = rootURL
        self.manifestURL = rootURL.appendingPathComponent("manifest.json")
        self.offlineDownloadsEnabled = offlineDownloadsEnabled
        self.settings = settings
        self.clockMs = clockMs

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try? mutableRoot.setResourceValues(resourceValues)

        if let data = try? Data(contentsOf: manifestURL),
            let env = try? JSONDecoder().decode(ManifestEnvelope.self, from: data)
        {
            for rec in env.items {
                let fileURL = rootURL.appendingPathComponent(rec.fileName)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    records["\(rec.userId)\u{1F}\(rec.videoId)"] = rec
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

    public func updateSettings(_ newSettings: OfflineDownloadSettings) throws {
        settings = newSettings
        purgeInactive()
        try persistManifest()
    }

    /// Saves a downloaded temporary file (`URLSessionDownloadTask`) as a plain local media file.
    /// Never persists signed URLs and never silently evicts active user downloads.
    @discardableResult
    public func saveFromFile(
        _ request: OfflineDownloadRequest,
        sourceURL: URL
    ) throws -> OfflineDownloadRecord {
        guard offlineDownloadsEnabled else { throw OfflineDownloadError.featureOff }
        if let thumb = request.thumbnailPath,
            thumb.hasPrefix("http://") || thumb.hasPrefix("https://")
        {
            throw OfflineDownloadError.signedURLForbidden
        }
        purgeInactive()

        let rKey = recordKey(userId: request.userId, videoId: request.videoId)
        let isReplacing = records[rKey] != nil
        if !isReplacing, let maxVideos = settings.maxVideos {
            let activeForUser = records.values.filter { $0.userId == request.userId && $0.isPlayable }.count
            if activeForUser >= maxVideos {
                throw OfflineDownloadError.maxVideosExceeded
            }
        }

        let used = totalUsedBytes() - (records[rKey]?.bytes ?? 0)
        let incomingSize =
            ((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        if settings.maxStorageBytes > 0 && incomingSize > 0 && used + incomingSize > settings.maxStorageBytes {
            throw OfflineDownloadError.storageBudgetExceeded
        }

        let ext = request.quality == .audio ? "m4a" : "mp4"
        let sanitized = "\(request.userId)_\(request.videoId)".replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
        let safeName = "\(sanitized).\(ext)"
        let dest = rootURL.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        if let prev = records[rKey], prev.fileName != safeName {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(prev.fileName))
        }

        let ts = clockMs()
        let record = OfflineDownloadRecord(
            userId: request.userId,
            videoId: request.videoId,
            title: request.title,
            titleAr: request.titleAr,
            channelName: request.channelName,
            thumbnailPath: request.thumbnailPath,
            durationSeconds: request.durationSeconds,
            quality: request.quality,
            fileName: safeName,
            bytes: incomingSize,
            downloadedAtMs: ts,
            lastAccessedAtMs: ts,
            status: .ready
        )
        records[rKey] = record
        try persistManifest()
        return record
    }

    /// Returns the local `file://` URL for direct `AVPlayer` playback.
    public func localFileURL(userId: String, videoId: String) throws -> URL {
        let rKey = recordKey(userId: userId, videoId: videoId)
        guard var rec = records[rKey], rec.isPlayable else { throw OfflineDownloadError.notFound }
        let fileURL = rootURL.appendingPathComponent(rec.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw OfflineDownloadError.notFound }
        rec.lastAccessedAtMs = clockMs()
        records[rKey] = rec
        try persistManifest()
        return fileURL
    }

    /// Creates a standard `AVURLAsset` pointing directly at the plain local media file.
    public func makePlayableAsset(userId: String, videoId: String) throws -> AVURLAsset {
        AVURLAsset(url: try localFileURL(userId: userId, videoId: videoId))
    }

    public func playableDownloads(userId: String) -> [OfflineDownloadRecord] {
        guard offlineDownloadsEnabled else { return [] }
        return records.values
            .filter { $0.userId == userId && $0.isPlayable }
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

    @discardableResult
    public func remove(userId: String, videoId: String) throws -> Bool {
        let rKey = recordKey(userId: userId, videoId: videoId)
        guard let removed = records.removeValue(forKey: rKey) else { return false }
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(removed.fileName))
        if let thumb = removed.thumbnailPath {
            try? FileManager.default.removeItem(atPath: thumb)
        }
        try persistManifest()
        return true
    }

    /// Applies hygiene availability sync decisions from `POST /api/v1/downloads/sync`.
    /// Deletes local copies for videos that went private, were deleted, or had downloads disabled.
    @discardableResult
    public func applyAvailabilitySync(_ decisions: [AvailabilitySyncDecision]) throws -> Int {
        var deleted = 0
        for d in decisions where !d.available {
            let matchingKeys = records.filter { $0.value.videoId == d.videoId }.map(\.key)
            for key in matchingKeys {
                if let existing = records.removeValue(forKey: key) {
                    try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(existing.fileName))
                    if let thumb = existing.thumbnailPath {
                        try? FileManager.default.removeItem(atPath: thumb)
                    }
                    deleted += 1
                }
            }
        }
        if deleted > 0 {
            try persistManifest()
        }
        return deleted
    }

    @discardableResult
    public func clearForUser(_ userId: String) throws -> Int {
        let keys = records.filter { $0.value.userId == userId }.map(\.key)
        for k in keys {
            if let rec = records.removeValue(forKey: k) {
                try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(rec.fileName))
                if let thumb = rec.thumbnailPath {
                    try? FileManager.default.removeItem(atPath: thumb)
                }
            }
        }
        try persistManifest()
        return keys.count
    }

    public func wipeAll() {
        for rec in records.values {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(rec.fileName))
            if let thumb = rec.thumbnailPath {
                try? FileManager.default.removeItem(atPath: thumb)
            }
        }
        records.removeAll()
        try? FileManager.default.removeItem(at: manifestURL)
    }

    private func purgeInactive() {
        let inactive = records.filter { !$0.value.isPlayable }.map(\.key)
        for k in inactive {
            if let rec = records.removeValue(forKey: k) {
                try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(rec.fileName))
            }
        }
    }

    private func persistManifest() throws {
        let env = ManifestEnvelope(
            version: 3,
            items: Array(records.values)
        )
        let data = try JSONEncoder().encode(env)
        try data.write(to: manifestURL, options: [.atomic])
    }
}

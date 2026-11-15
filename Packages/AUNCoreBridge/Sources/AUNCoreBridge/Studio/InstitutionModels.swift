import Foundation

/// The account's brand kit (`GET|PUT /api/studio/brand-kit`), shared by every channel it owns and their teams.
public struct BrandKit: Hashable, Sendable, Codable {
    public struct Name: Hashable, Sendable, Codable {
        public var en: String?
        public var ar: String?
        public init(en: String? = nil, ar: String? = nil) {
            self.en = en
            self.ar = ar
        }
    }

    public struct Colors: Hashable, Sendable, Codable {
        /// `#rrggbb`.
        public var primary: String
        public var secondary: String
        public var text: String
        public var background: String
        public init(primary: String, secondary: String, text: String, background: String) {
            self.primary = primary
            self.secondary = secondary
            self.text = text
            self.background = background
        }
    }

    public enum LowerThirdStyle: String, Sendable, Hashable, Codable, CaseIterable { case bar, box, minimal }
    public enum LowerThirdPosition: String, Sendable, Hashable, Codable, CaseIterable { case start, center, end }
    public enum Watermark: String, Sendable, Hashable, Codable, CaseIterable {
        case none, topStart = "top-start", topEnd = "top-end", bottomStart = "bottom-start", bottomEnd = "bottom-end"
    }

    public struct LowerThird: Hashable, Sendable, Codable {
        public var style: LowerThirdStyle
        public var position: LowerThirdPosition
        public init(style: LowerThirdStyle = .bar, position: LowerThirdPosition = .start) {
            self.style = style
            self.position = position
        }
    }

    public var name: Name
    public var colors: Colors
    /// Asset ids from the library: an image for the logo, videos for the intro and outro.
    public var logo: String?
    public var intro: String?
    public var outro: String?
    public var lowerThird: LowerThird
    public var watermark: Watermark

    public init(
        name: Name = Name(), colors: Colors = BrandKit.defaultColors, logo: String? = nil, intro: String? = nil,
        outro: String? = nil, lowerThird: LowerThird = LowerThird(), watermark: Watermark = .none
    ) {
        self.name = name
        self.colors = colors
        self.logo = logo
        self.intro = intro
        self.outro = outro
        self.lowerThird = lowerThird
        self.watermark = watermark
    }

    /// The server's defaults (Fanous night teal, lantern and parchment).
    public static let defaultColors = Colors(primary: "#ffa037", secondary: "#093041", text: "#f7f1e8", background: "#093041")

    /// The name for a language, falling back to the other one.
    public func displayName(_ language: AppLanguage) -> String? {
        let preferred = language == .ar ? name.ar : name.en
        let other = language == .ar ? name.en : name.ar
        return [preferred, other].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// `#rrggbb`, as the server validates it.
    public static func isValidColor(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy(\.isHexDigit)
    }
}

/// The kit with whether this account may change it (a team member acting as a channel reads the owner's kit).
public struct BrandKitState: Hashable, Sendable, Decodable {
    public var kit: BrandKit
    public var saved: Bool
    public var canEdit: Bool

    public init(kit: BrandKit, saved: Bool, canEdit: Bool) {
        self.kit = kit
        self.saved = saved
        self.canEdit = canEdit
    }
}

/// A file in the shared asset library.
public struct StudioAsset: Identifiable, Hashable, Sendable, Decodable {
    public enum Kind: String, Sendable, Hashable, Decodable, CaseIterable { case image, video, audio }
    public var id: String
    public var kind: Kind
    public var name: String
    public var contentType: String
    public var bytes: Int64
    public var createdAt: Date?

    public init(id: String, kind: Kind, name: String, contentType: String, bytes: Int64, createdAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.contentType = contentType
        self.bytes = bytes
        self.createdAt = createdAt
    }
}

public struct StudioAssetLibrary: Hashable, Sendable, Decodable {
    public struct Limits: Hashable, Sendable, Decodable {
        public var maxAssets: Int
        public var maxAssetBytes: Int64
        public var maxTotalBytes: Int64
        public init(maxAssets: Int = 50, maxAssetBytes: Int64 = 95 * 1024 * 1024, maxTotalBytes: Int64 = 1024 * 1024 * 1024) {
            self.maxAssets = maxAssets
            self.maxAssetBytes = maxAssetBytes
            self.maxTotalBytes = maxTotalBytes
        }
    }

    public var assets: [StudioAsset]
    public var bytes: Int64
    public var limits: Limits
    public var canEdit: Bool

    public init(assets: [StudioAsset], bytes: Int64? = nil, limits: Limits = Limits(), canEdit: Bool = true) {
        self.assets = assets
        self.bytes = bytes ?? assets.reduce(0) { $0 + $1.bytes }
        self.limits = limits
        self.canEdit = canEdit
    }

    /// Why a new file cannot be added, checked before uploading so a full library never sends the bytes.
    public func refusal(forFileOfSize size: Int64) -> String? {
        if size <= 0 { return "empty" }
        if size > limits.maxAssetBytes { return "too_large" }
        if assets.count >= limits.maxAssets || bytes + size > limits.maxTotalBytes { return "library_full" }
        return nil
    }
}

// MARK: Deep analytics

/// Lifetime totals (`GET /api/analytics/summary`).
public struct AnalyticsSummary: Hashable, Sendable, Decodable {
    public var totalViews: Int
    public var totalLikes: Int
    public var totalComments: Int
    public var totalSubscribers: Int
    public var totalVideos: Int
    public var averageViewsPerVideo: Double
    /// Percent.
    public var engagementRate: Double

    public init(
        totalViews: Int, totalLikes: Int = 0, totalComments: Int = 0, totalSubscribers: Int = 0, totalVideos: Int = 0,
        averageViewsPerVideo: Double = 0, engagementRate: Double = 0
    ) {
        self.totalViews = totalViews
        self.totalLikes = totalLikes
        self.totalComments = totalComments
        self.totalSubscribers = totalSubscribers
        self.totalVideos = totalVideos
        self.averageViewsPerVideo = averageViewsPerVideo
        self.engagementRate = engagementRate
    }

    enum CodingKeys: String, CodingKey {
        case totalViews, totalLikes, totalComments, totalSubscribers, totalVideos, engagementRate
        case averageViewsPerVideo = "avgViewsPerVideo"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) throws -> Int { Int(try c.decodeIfPresent(Double.self, forKey: key) ?? 0) }
        totalViews = try int(.totalViews)
        totalLikes = try int(.totalLikes)
        totalComments = try int(.totalComments)
        totalSubscribers = try int(.totalSubscribers)
        totalVideos = try int(.totalVideos)
        averageViewsPerVideo = try c.decodeIfPresent(Double.self, forKey: .averageViewsPerVideo) ?? 0
        engagementRate = try c.decodeIfPresent(Double.self, forKey: .engagementRate) ?? 0
    }
}

/// Share of viewers still watching at each 5 % of a video. `points` is nil below the server's minimum of starts.
public struct RetentionCurve: Hashable, Sendable, Decodable {
    public struct Point: Hashable, Sendable, Decodable, Identifiable {
        /// Percent of the video, 0–100.
        public var bucket: Double
        /// 0–1.
        public var share: Double
        public var id: Double { bucket }
        public init(bucket: Double, share: Double) {
            self.bucket = bucket
            self.share = share
        }
    }

    public var starts: Int
    public var points: [Point]?

    public init(starts: Int, points: [Point]?) {
        self.starts = starts
        self.points = points
    }
}

// MARK: Pre-encoded renditions (D11)

/// One file of a rung, as declared to `POST /api/videos/:id/renditions` (`<rung>/<file>`).
public struct StagedFile: Hashable, Sendable, Codable {
    public var path: String
    public var bytes: Int64

    public init(path: String, bytes: Int64) {
        self.path = path
        self.bytes = bytes
    }

    /// The rung and file name of the path, for the PUT route.
    public var parts: (rung: String, file: String)? {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else { return nil }
        return (String(pieces[0]), String(pieces[1]))
    }
}

public struct RenditionStaging: Hashable, Sendable, Decodable {
    public var stagingID: String
    public var status: String
    public var maxFileBytes: Int64?

    public init(stagingID: String, status: String = "uploading", maxFileBytes: Int64? = nil) {
        self.stagingID = stagingID
        self.status = status
        self.maxFileBytes = maxFileBytes
    }

    enum CodingKeys: String, CodingKey {
        case stagingID = "stagingId"
        case status, maxFileBytes
    }
}

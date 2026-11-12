import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Hashable, Sendable {
    case en, ar

    public var isRTL: Bool { self == .ar }
    public var locale: Locale { Locale(identifier: rawValue) }
}

/// Server text with per-language variants. Empty variants count as missing.
public struct LocalizedText: Codable, Hashable, Sendable {
    public var en: String?
    public var ar: String?

    public init(en: String? = nil, ar: String? = nil) {
        self.en = en
        self.ar = ar
    }

    public func value(for language: AppLanguage, fallback: String) -> String {
        let preferred = (language == .ar ? ar : en)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preferred, !preferred.isEmpty { return preferred }
        return fallback
    }
}

public struct Video: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var title: String
    public var titleLocalized: LocalizedText?
    public var description: String?
    public var descriptionLocalized: LocalizedText?
    public var thumbnailURL: URL?
    public var playURL: URL?
    public var channelID: String?
    public var channelName: String?
    public var views: Int
    public var durationSeconds: Double?
    public var category: String?
    public var dateCreated: Date?
    public var availableResolutions: [String]
    public var uploadStatus: String?
    public var isLive: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, titleLocalized, description, descriptionLocalized, channelName, views, category
        case dateCreated, availableResolutions, uploadStatus, isLive
        case thumbnailURL = "thumbnailUrl"
        case playURL = "playUrl"
        case channelID = "channelId"
        case durationSeconds = "duration"
    }

    public init(
        id: String, title: String, titleLocalized: LocalizedText? = nil, description: String? = nil,
        descriptionLocalized: LocalizedText? = nil, thumbnailURL: URL? = nil, playURL: URL? = nil,
        channelID: String? = nil, channelName: String? = nil, views: Int = 0, durationSeconds: Double? = nil,
        category: String? = nil, dateCreated: Date? = nil, availableResolutions: [String] = [],
        uploadStatus: String? = "ready", isLive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.titleLocalized = titleLocalized
        self.description = description
        self.descriptionLocalized = descriptionLocalized
        self.thumbnailURL = thumbnailURL
        self.playURL = playURL
        self.channelID = channelID
        self.channelName = channelName
        self.views = views
        self.durationSeconds = durationSeconds
        self.category = category
        self.dateCreated = dateCreated
        self.availableResolutions = availableResolutions
        self.uploadStatus = uploadStatus
        self.isLive = isLive
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        titleLocalized = try c.decodeIfPresent(LocalizedText.self, forKey: .titleLocalized)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        descriptionLocalized = try c.decodeIfPresent(LocalizedText.self, forKey: .descriptionLocalized)
        thumbnailURL = try? c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        playURL = try? c.decodeIfPresent(URL.self, forKey: .playURL)
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
        channelName = try c.decodeIfPresent(String.self, forKey: .channelName)
        views = try c.decodeIfPresent(Int.self, forKey: .views) ?? 0
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        dateCreated = try c.decodeIfPresent(Date.self, forKey: .dateCreated)
        availableResolutions = try c.decodeIfPresent([String].self, forKey: .availableResolutions) ?? []
        uploadStatus = try c.decodeIfPresent(String.self, forKey: .uploadStatus)
        isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
    }

    public var isPlayable: Bool { uploadStatus == "ready" && playURL != nil }

    public func displayTitle(_ language: AppLanguage) -> String {
        titleLocalized?.value(for: language, fallback: title) ?? title
    }

    public func displayDescription(_ language: AppLanguage) -> String {
        let plain = description ?? ""
        return descriptionLocalized?.value(for: language, fallback: plain) ?? plain
    }
}

public enum HomeRailKind: String, CaseIterable, Hashable, Sendable {
    case trending, recommended, popular, recent
}

public struct HomeRail: Identifiable, Hashable, Sendable {
    public var kind: HomeRailKind
    public var videos: [Video]
    public var id: HomeRailKind { kind }

    public init(kind: HomeRailKind, videos: [Video]) {
        self.kind = kind
        self.videos = videos
    }
}

public struct SubtitleTrack: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var language: String
    public var label: String
    public var url: URL
    public var isDefault: Bool

    public init(id: String, language: String, label: String, url: URL, isDefault: Bool = false) {
        self.id = id
        self.language = language
        self.label = label
        self.url = url
        self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey { case id, language, label, url, isDefault }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        language = try c.decode(String.self, forKey: .language)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? language
        url = try c.decode(URL.self, forKey: .url)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

public struct Chapter: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var startTime: Double
    public var endTime: Double?
    public var title: String
    public var titleLocalized: LocalizedText?

    public init(id: String, startTime: Double, endTime: Double? = nil, title: String, titleLocalized: LocalizedText? = nil) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.titleLocalized = titleLocalized
    }

    public func displayTitle(_ language: AppLanguage) -> String {
        titleLocalized?.value(for: language, fallback: title) ?? title
    }
}

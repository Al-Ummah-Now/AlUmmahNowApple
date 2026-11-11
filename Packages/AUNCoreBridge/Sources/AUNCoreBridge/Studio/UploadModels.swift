import Foundation

/// Video categories, the fixed list shared with the web (`VideoCategory`).
public enum VideoCategory: String, CaseIterable, Sendable, Codable {
    case quranRecitation = "quran_recitation", quranTafsir = "quran_tafsir", hadithStudies = "hadith_studies"
    case islamicHistory = "islamic_history", fiqh, aqeedah, dawah, khutbah
    case islamicLectures = "islamic_lectures", islamicNasheed = "islamic_nasheed", islamicKids = "islamic_kids"
    case islamicNews = "islamic_news", hajjUmrah = "hajj_umrah", ramadan, islamicLifestyle = "islamic_lifestyle"
}

/// Languages the server accepts for a video.
public enum VideoLanguage: String, CaseIterable, Sendable, Codable { case en, ar, ur, fr }

/// Who can see a new upload.
public enum UploadVisibility: String, CaseIterable, Sendable, Codable {
    case `public`, `private`, draft
}

/// A playlist of a channel (`GET /api/channels/:id/playlists`).
public struct StudioPlaylist: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var title: String
    public var isPublic: Bool

    public init(id: String, title: String, isPublic: Bool = true) {
        self.id = id
        self.title = title
        self.isPublic = isPublic
    }

    enum CodingKeys: String, CodingKey { case id, title, isPublic }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic) ?? true
    }
}

/// The "set for all" values of an upload batch. Each file can still override its title.
public struct UploadSettings: Hashable, Sendable, Codable {
    /// Title with tokens such as `{{filename}}` or `{{episode}}`; see `TitlePattern`.
    public var titlePattern: String
    public var description: String
    public var category: VideoCategory?
    public var language: VideoLanguage?
    public var visibility: UploadVisibility
    public var playlistIDs: [String]
    public var tags: [String]
    /// When set, the first video is published then, and each next one `scheduleIntervalMinutes` later.
    public var scheduleAt: Date?
    public var scheduleIntervalMinutes: Int
    /// `{{episode}}` of the first file.
    public var firstEpisode: Int

    public init(
        titlePattern: String = TitlePattern.defaultPattern, description: String = "", category: VideoCategory? = nil,
        language: VideoLanguage? = nil, visibility: UploadVisibility = .public, playlistIDs: [String] = [],
        tags: [String] = [], scheduleAt: Date? = nil, scheduleIntervalMinutes: Int = 0, firstEpisode: Int = 1
    ) {
        self.titlePattern = titlePattern
        self.description = description
        self.category = category
        self.language = language
        self.visibility = visibility
        self.playlistIDs = playlistIDs
        self.tags = tags
        self.scheduleAt = scheduleAt
        self.scheduleIntervalMinutes = scheduleIntervalMinutes
        self.firstEpisode = firstEpisode
    }

    /// The publish time of the file at `index`, or nil when not scheduled.
    public func scheduleDate(at index: Int) -> Date? {
        scheduleAt.map { $0.addingTimeInterval(Double(index * max(0, scheduleIntervalMinutes)) * 60) }
    }
}

/// Title tokens, in the web's `{{name}}` template syntax.
public enum TitlePattern {
    public static let defaultPattern = "{{filename}}"

    /// Tokens offered in the editor, in display order.
    public static let tokens = [
        "filename", "episode", "n", "channel_name", "date", "year", "month", "day", "weekday", "hijri_date", "hijri_year",
        "hijri_month",
    ]

    public struct Context: Sendable {
        public var filename: String
        /// Position in the batch, from 0.
        public var index: Int
        public var firstEpisode: Int
        public var channelName: String
        public var date: Date
        public var language: AppLanguage
        public var timeZone: TimeZone

        public init(
            filename: String, index: Int = 0, firstEpisode: Int = 1, channelName: String = "", date: Date = Date(),
            language: AppLanguage = .en, timeZone: TimeZone = .current
        ) {
            self.filename = filename
            self.index = index
            self.firstEpisode = firstEpisode
            self.channelName = channelName
            self.date = date
            self.language = language
            self.timeZone = timeZone
        }
    }

    /// Replaces every known token; unknown tokens stay as typed. Never returns an empty title.
    public static func render(_ pattern: String, _ context: Context) -> String {
        let base = (context.filename as NSString).deletingPathExtension
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = context.timeZone
        var hijri = Calendar(identifier: .islamicUmmAlQura)
        hijri.timeZone = context.timeZone
        let locale = context.language.locale
        let parts = gregorian.dateComponents([.year, .month, .day], from: context.date)
        let hijriParts = hijri.dateComponents([.year, .month, .day], from: context.date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        func formatted(_ calendar: Calendar, _ template: String) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = context.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: context.date)
        }
        let values: [String: String] = [
            "filename": base,
            "episode": String(context.firstEpisode + context.index),
            "n": String(context.index + 1),
            "channel_name": context.channelName,
            "date": "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day))",
            "year": String(parts.year ?? 0),
            "month": two(parts.month),
            "day": two(parts.day),
            "weekday": formatted(gregorian, "EEEE"),
            "hijri_date": formatted(hijri, "d MMMM y"),
            "hijri_year": String(hijriParts.year ?? 0),
            "hijri_month": formatted(hijri, "MMMM"),
        ]
        var result = pattern
        for (token, value) in values { result = result.replacingOccurrences(of: "{{\(token)}}", with: value) }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? base : String(trimmed.prefix(200))
    }
}

/// What `POST /api/videos/upload/initiate` needs for one file.
public struct UploadInitiation: Hashable, Sendable, Encodable {
    public var title: String
    public var description: String?
    public var fileSize: Int64
    public var mimeType: String
    public var isPublic: Bool
    public var isDraft: Bool?
    /// Comma-separated, as the server stores them.
    public var tags: String?
    public var category: String?

    public init(
        title: String, description: String?, fileSize: Int64, mimeType: String, isPublic: Bool, isDraft: Bool?,
        tags: String?, category: String?
    ) {
        self.title = title
        self.description = description
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.isPublic = isPublic
        self.isDraft = isDraft
        self.tags = tags
        self.category = category
    }
}

/// The server's answer to initiate or resume: where and how to send the bytes.
public struct UploadTicket: Hashable, Sendable, Codable {
    public var videoID: String
    public var tusSessionID: String
    public var chunkSize: Int
    /// Set when the server reuses an earlier unfinished upload: resume at `/api/videos/tus/<id>`.
    public var tusUploadID: String?

    public init(videoID: String, tusSessionID: String, chunkSize: Int, tusUploadID: String? = nil) {
        self.videoID = videoID
        self.tusSessionID = tusSessionID
        self.chunkSize = chunkSize
        self.tusUploadID = tusUploadID
    }

    enum CodingKeys: String, CodingKey {
        case videoID = "videoId"
        case tusSessionID = "tusSessionId"
        case tusUploadID = "tusUploadId"
        case chunkSize
    }
}

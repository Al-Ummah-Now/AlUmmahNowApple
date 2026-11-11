import Foundation

/// Where a video is in Studio. The server derives it (`studioVideoStatus`).
public enum StudioStatus: String, CaseIterable, Sendable, Codable {
    case published, scheduled, drafts, processing, failed
}

public enum ContentSort: String, CaseIterable, Sendable { case newest, oldest, views, title }
public enum ContentVisibility: String, CaseIterable, Sendable { case all, `public`, `private` }

/// A soft-deleted video in Recently deleted (`GET /api/channels/:id/content/deleted`).
public struct DeletedVideo: Identifiable, Hashable, Sendable, Decodable {
    public enum Status: String, Sendable, Decodable { case deleted, queued, purging, purged }

    public var id: String
    public var title: String
    public var deletedAt: Date?
    /// When the hourly cleanup erases it, unless restored first.
    public var purgeAfter: Date?
    public var status: Status

    public init(id: String, title: String, deletedAt: Date? = nil, purgeAfter: Date? = nil, status: Status = .deleted) {
        self.id = id
        self.title = title
        self.deletedAt = deletedAt
        self.purgeAfter = purgeAfter
        self.status = status
    }

    enum CodingKeys: String, CodingKey { case id, title, deletedAt, purgeAfter, status }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        deletedAt = try? c.decodeIfPresent(Date.self, forKey: .deletedAt)
        purgeAfter = try? c.decodeIfPresent(Date.self, forKey: .purgeAfter)
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .deleted
    }

    /// Restore is possible until permanent deletion starts.
    public var canRestore: Bool { status == .deleted || status == .queued }
}

/// Counts per Studio tab (`GET /api/channels/:id/content/summary`).
public typealias ContentCounts = [StudioStatus: Int]

/// One row of the Studio content list.
public struct StudioVideo: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var title: String
    public var titleLocalized: LocalizedText?
    public var description: String?
    public var descriptionLocalized: LocalizedText?
    public var thumbnailURL: URL?
    public var channelID: String?
    public var isPublic: Bool
    public var isDraft: Bool
    public var tags: [String]
    public var category: String?
    public var language: String?
    public var durationSeconds: Double?
    public var views: Int
    public var likes: Int
    public var comments: Int
    public var dateCreated: Date?
    public var uploadStatus: String?
    public var studioStatus: StudioStatus?
    public var failureKind: String?
    public var scheduledPublishDate: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, titleLocalized, description, descriptionLocalized, isPublic, isDraft, tags, category, language
        case views, dateCreated, uploadStatus, studioStatus, failureKind, scheduledPublishDate
        case thumbnailURL = "thumbnailUrl"
        case channelID = "channelId"
        case durationSeconds = "duration"
        case likes = "likesCount"
        case comments = "commentsCount"
    }

    public init(
        id: String, title: String, titleLocalized: LocalizedText? = nil, description: String? = nil,
        descriptionLocalized: LocalizedText? = nil, thumbnailURL: URL? = nil, channelID: String? = nil, isPublic: Bool = true,
        isDraft: Bool = false, tags: [String] = [], category: String? = nil, language: String? = nil,
        durationSeconds: Double? = nil, views: Int = 0, likes: Int = 0, comments: Int = 0, dateCreated: Date? = nil,
        uploadStatus: String? = "ready", studioStatus: StudioStatus? = .published, failureKind: String? = nil,
        scheduledPublishDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.titleLocalized = titleLocalized
        self.description = description
        self.descriptionLocalized = descriptionLocalized
        self.thumbnailURL = thumbnailURL
        self.channelID = channelID
        self.isPublic = isPublic
        self.isDraft = isDraft
        self.tags = tags
        self.category = category
        self.language = language
        self.durationSeconds = durationSeconds
        self.views = views
        self.likes = likes
        self.comments = comments
        self.dateCreated = dateCreated
        self.uploadStatus = uploadStatus
        self.studioStatus = studioStatus
        self.failureKind = failureKind
        self.scheduledPublishDate = scheduledPublishDate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        titleLocalized = try? c.decodeIfPresent(LocalizedText.self, forKey: .titleLocalized)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        descriptionLocalized = try? c.decodeIfPresent(LocalizedText.self, forKey: .descriptionLocalized)
        thumbnailURL = try? c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
        isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic) ?? true
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        // Older records store tags as a comma-separated string.
        if let list = try? c.decodeIfPresent([String].self, forKey: .tags) {
            tags = list
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .tags) {
            tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            tags = []
        }
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        durationSeconds = try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        views = (try? c.decodeIfPresent(Int.self, forKey: .views)) ?? 0
        likes = (try? c.decodeIfPresent(Int.self, forKey: .likes)) ?? 0
        comments = (try? c.decodeIfPresent(Int.self, forKey: .comments)) ?? 0
        dateCreated = try? c.decodeIfPresent(Date.self, forKey: .dateCreated)
        uploadStatus = try? c.decodeIfPresent(String.self, forKey: .uploadStatus)
        studioStatus = try? c.decodeIfPresent(StudioStatus.self, forKey: .studioStatus)
        failureKind = try? c.decodeIfPresent(String.self, forKey: .failureKind)
        scheduledPublishDate = try? c.decodeIfPresent(Date.self, forKey: .scheduledPublishDate)
    }

    public func displayTitle(_ language: AppLanguage) -> String {
        titleLocalized?.value(for: language, fallback: title) ?? title
    }
}

public struct ContentQuery: Hashable, Sendable {
    public var status: StudioStatus
    public var text: String
    public var visibility: ContentVisibility
    public var sort: ContentSort
    public var limit: Int

    public init(
        status: StudioStatus = .published, text: String = "", visibility: ContentVisibility = .all,
        sort: ContentSort = .newest, limit: Int = 30
    ) {
        self.status = status
        self.text = text
        self.visibility = visibility
        self.sort = sort
        self.limit = limit
    }
}

public struct ContentPage: Hashable, Sendable {
    public var items: [StudioVideo]
    public var cursor: String?

    public init(items: [StudioVideo], cursor: String?) {
        self.items = items
        self.cursor = cursor
    }
}

/// Fields a single-video edit can change. `nil` leaves a field as it is.
public struct VideoEdit: Hashable, Sendable, Encodable {
    public var title: String?
    public var description: String?
    public var isPublic: Bool?
    public var category: String?
    public var tags: [String]?
    public var language: String?

    public init(
        title: String? = nil, description: String? = nil, isPublic: Bool? = nil, category: String? = nil,
        tags: [String]? = nil, language: String? = nil
    ) {
        self.title = title
        self.description = description
        self.isPublic = isPublic
        self.category = category
        self.tags = tags
        self.language = language
    }
}

/// Changes applied to many videos at once (`POST /api/videos/bulk-update`).
public struct BulkChanges: Hashable, Sendable, Encodable {
    public var isPublic: Bool?
    public var category: String?
    public var addTags: [String]?
    public var removeTags: [String]?

    public init(isPublic: Bool? = nil, category: String? = nil, addTags: [String]? = nil, removeTags: [String]? = nil) {
        self.isPublic = isPublic
        self.category = category
        self.addTags = addTags
        self.removeTags = removeTags
    }

    public var isEmpty: Bool {
        isPublic == nil && category == nil && (addTags ?? []).isEmpty && (removeTags ?? []).isEmpty
    }
}

/// Per-video outcome of a bulk action.
public struct BulkResult: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public var videoID: String
        public var success: Bool
        public var error: String?

        public init(videoID: String, success: Bool, error: String? = nil) {
            self.videoID = videoID
            self.success = success
            self.error = error
        }
    }

    public var items: [Item]
    public init(items: [Item]) { self.items = items }
    public var succeeded: Int { items.filter(\.success).count }
    public var failed: [Item] { items.filter { !$0.success } }
}

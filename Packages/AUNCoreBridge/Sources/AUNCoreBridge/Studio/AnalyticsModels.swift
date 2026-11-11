import Foundation

/// The analytics ranges the web Studio offers; each is compared with the period of equal length before it.
public enum AnalyticsRange: Int, CaseIterable, Sendable, Hashable {
    case days7 = 7, days28 = 28, days90 = 90, days365 = 365

    /// The current period and the one before it, ending now.
    public func periods(now: Date = Date()) -> (current: DateInterval, previous: DateInterval) {
        let length = TimeInterval(rawValue) * 24 * 60 * 60
        let start = now.addingTimeInterval(-length)
        return (DateInterval(start: start, end: now), DateInterval(start: start.addingTimeInterval(-length), end: start))
    }
}

/// One day of a channel (`Metric`).
public struct DailyMetric: Hashable, Sendable, Decodable, Identifiable {
    public var date: String
    public var views: Int
    public var likes: Int
    public var comments: Int
    public var subscribers: Int
    /// Seconds.
    public var watchTime: Double
    public var id: String { date }

    public init(date: String, views: Int, likes: Int = 0, comments: Int = 0, subscribers: Int = 0, watchTime: Double = 0) {
        self.date = date
        self.views = views
        self.likes = likes
        self.comments = comments
        self.subscribers = subscribers
        self.watchTime = watchTime
    }

    enum CodingKeys: String, CodingKey { case date, views, likes, comments, subscribers, watchTime }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        views = Int(try c.decodeIfPresent(Double.self, forKey: .views) ?? 0)
        likes = Int(try c.decodeIfPresent(Double.self, forKey: .likes) ?? 0)
        comments = Int(try c.decodeIfPresent(Double.self, forKey: .comments) ?? 0)
        subscribers = Int(try c.decodeIfPresent(Double.self, forKey: .subscribers) ?? 0)
        watchTime = try c.decodeIfPresent(Double.self, forKey: .watchTime) ?? 0
    }

    /// The day, read from `YYYY-MM-DD` or a full ISO date.
    public var day: Date? {
        let prefix = String(date.prefix(10))
        return try? Date(prefix + "T00:00:00Z", strategy: .iso8601)
    }
}

/// A video's numbers in a range (`VideoAnalytics`).
public struct VideoStats: Hashable, Sendable, Decodable, Identifiable {
    public var videoID: String
    public var title: String
    public var views: Int
    public var likes: Int
    public var comments: Int
    public var shares: Int
    /// Seconds watched in the range.
    public var watchTime: Double
    /// Seconds.
    public var averageViewDuration: Double
    /// Percent.
    public var engagementRate: Double
    public var thumbnailURL: URL?
    public var id: String { videoID }

    public init(
        videoID: String, title: String, views: Int, likes: Int = 0, comments: Int = 0, shares: Int = 0,
        watchTime: Double = 0, averageViewDuration: Double = 0, engagementRate: Double = 0, thumbnailURL: URL? = nil
    ) {
        self.videoID = videoID
        self.title = title
        self.views = views
        self.likes = likes
        self.comments = comments
        self.shares = shares
        self.watchTime = watchTime
        self.averageViewDuration = averageViewDuration
        self.engagementRate = engagementRate
        self.thumbnailURL = thumbnailURL
    }

    enum CodingKeys: String, CodingKey {
        case videoID = "videoId", title, views, likes, comments, shares, watchTime, engagementRate
        case averageViewDuration = "avgViewDuration"
        case thumbnailURL = "thumbnailUrl"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoID = try c.decode(String.self, forKey: .videoID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        views = Int(try c.decodeIfPresent(Double.self, forKey: .views) ?? 0)
        likes = Int(try c.decodeIfPresent(Double.self, forKey: .likes) ?? 0)
        comments = Int(try c.decodeIfPresent(Double.self, forKey: .comments) ?? 0)
        shares = Int(try c.decodeIfPresent(Double.self, forKey: .shares) ?? 0)
        watchTime = try c.decodeIfPresent(Double.self, forKey: .watchTime) ?? 0
        averageViewDuration = try c.decodeIfPresent(Double.self, forKey: .averageViewDuration) ?? 0
        engagementRate = try c.decodeIfPresent(Double.self, forKey: .engagementRate) ?? 0
        thumbnailURL = try? c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
    }
}

/// A channel's numbers in a range (`GET /api/analytics/channels/:id`).
public struct ChannelStats: Hashable, Sendable, Decodable {
    public var totalViews: Int
    public var totalVideos: Int
    public var totalSubscribers: Int
    public var totalLikes: Int
    public var totalComments: Int
    /// Percent.
    public var engagementRate: Double
    public var topVideos: [VideoStats]
    public var daily: [DailyMetric]

    public init(
        totalViews: Int, totalVideos: Int = 0, totalSubscribers: Int = 0, totalLikes: Int = 0, totalComments: Int = 0,
        engagementRate: Double = 0, topVideos: [VideoStats] = [], daily: [DailyMetric] = []
    ) {
        self.totalViews = totalViews
        self.totalVideos = totalVideos
        self.totalSubscribers = totalSubscribers
        self.totalLikes = totalLikes
        self.totalComments = totalComments
        self.engagementRate = engagementRate
        self.topVideos = topVideos
        self.daily = daily
    }

    enum CodingKeys: String, CodingKey {
        case totalViews, totalVideos, totalSubscribers, totalLikes, totalComments
        case engagementRate = "avgEngagementRate"
        case topVideos = "topPerformingVideos"
        case daily = "recentMetrics"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) throws -> Int { Int(try c.decodeIfPresent(Double.self, forKey: key) ?? 0) }
        totalViews = try int(.totalViews)
        totalVideos = try int(.totalVideos)
        totalSubscribers = try int(.totalSubscribers)
        totalLikes = try int(.totalLikes)
        totalComments = try int(.totalComments)
        engagementRate = try c.decodeIfPresent(Double.self, forKey: .engagementRate) ?? 0
        topVideos = (try? c.decodeIfPresent([VideoStats].self, forKey: .topVideos)) ?? []
        daily = (try? c.decodeIfPresent([DailyMetric].self, forKey: .daily)) ?? []
    }

    // The `total*` counters are lifetime numbers; only the daily series follows the requested range. Period numbers
    // and comparisons come from the series, as on the web.
    public var periodViews: Int { daily.reduce(0) { $0 + $1.views } }
    public var periodSubscribers: Int { daily.reduce(0) { $0 + $1.subscribers } }
    public var watchTime: Double { daily.reduce(0) { $0 + $1.watchTime } }
}

/// Change from the previous period, as a fraction (0.25 is +25 %); nil when there is nothing to compare.
public func periodChange(_ current: Double, _ previous: Double) -> Double? {
    guard previous > 0 else { return nil }
    return (current - previous) / previous
}

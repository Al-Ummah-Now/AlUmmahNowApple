import Foundation

/// The analytics ranges the web Studio offers; each is compared with the period of equal length before it.
public enum AnalyticsRange: Int, CaseIterable, Sendable, Hashable {
    case days7 = 7, days28 = 28, days90 = 90, days365 = 365

    /// "Last N days": today (UTC) and the N−1 days before it, as the API counts both ends; then the N days before that.
    public func periods(now: Date = Date()) -> (current: DateInterval, previous: DateInterval) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(rawValue - 1), to: today) ?? today
        let previousStart = calendar.date(byAdding: .day, value: -rawValue, to: start) ?? start
        return (
            DateInterval(start: start, end: max(start, now)),
            DateInterval(start: previousStart, end: start.addingTimeInterval(-1))
        )
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
    /// Views, likes and comments in the requested range; nil from servers that only send lifetime numbers.
    public var rangeViews: Int?
    public var rangeLikes: Int?
    public var rangeComments: Int?
    /// One zero-filled UTC day per entry in the range (`recentMetrics`).
    public var daily: [DailyMetric]
    public var id: String { videoID }

    /// The range's numbers when the server sends them, else the plain ones.
    public var periodViews: Int { rangeViews ?? views }
    public var periodLikes: Int { rangeLikes ?? likes }
    public var periodComments: Int { rangeComments ?? comments }

    public init(
        videoID: String, title: String, views: Int, likes: Int = 0, comments: Int = 0, shares: Int = 0,
        watchTime: Double = 0, averageViewDuration: Double = 0, engagementRate: Double = 0, thumbnailURL: URL? = nil,
        rangeViews: Int? = nil, rangeLikes: Int? = nil, rangeComments: Int? = nil, daily: [DailyMetric] = []
    ) {
        self.rangeViews = rangeViews
        self.rangeLikes = rangeLikes
        self.rangeComments = rangeComments
        self.daily = daily
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
        case rangeViews, rangeLikes, rangeComments
        case daily = "recentMetrics"
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
        func optionalInt(_ key: CodingKeys) -> Int? {
            (try? c.decodeIfPresent(Double.self, forKey: key)).flatMap { $0 }.map { Int($0) }
        }
        rangeViews = optionalInt(.rangeViews)
        rangeLikes = optionalInt(.rangeLikes)
        rangeComments = optionalInt(.rangeComments)
        daily = (try? c.decodeIfPresent([DailyMetric].self, forKey: .daily)) ?? []
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

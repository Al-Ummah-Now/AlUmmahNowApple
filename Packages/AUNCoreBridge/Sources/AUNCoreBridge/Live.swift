import Foundation

/// Live streams and premieres for viewers (wiki E17): what is on, what is coming, and the chat beside it. Reading only:
/// the viewer has no account yet, and writing and reminders need one.
public enum LiveStatus: String, Decodable, Hashable, Sendable {
    case scheduled, live, ended, cancelled
}

public enum LiveKind: String, Decodable, Hashable, Sendable {
    case live, premiere
}

/// The four fixed event tags (shared-types `LIVE_EVENT_TYPES`).
public enum LiveEventType: String, CaseIterable, Decodable, Hashable, Sendable {
    case jumuah, taraweeh, conference, halqa
}

public struct LiveStream: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var title: String
    public var description: String?
    public var status: LiveStatus
    public var kind: LiveKind
    /// nil while event tags are off.
    public var eventType: LiveEventType?
    public var channelID: String?
    public var channelName: String?
    public var thumbnailURL: URL?
    public var scheduledStart: Date?
    public var startedAt: Date?
    public var viewers: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, kind, eventType, channelName
        case channelID = "channelId"
        case thumbnailURL = "thumbnailUrl"
        case scheduledStart = "scheduledStartTime"
        case startedAt = "actualStartTime"
        case viewers = "currentViewers"
    }

    public init(
        id: String, title: String, description: String? = nil, status: LiveStatus, kind: LiveKind = .live,
        eventType: LiveEventType? = nil, channelID: String? = nil, channelName: String? = nil, thumbnailURL: URL? = nil,
        scheduledStart: Date? = nil, startedAt: Date? = nil, viewers: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.kind = kind
        self.eventType = eventType
        self.channelID = channelID
        self.channelName = channelName
        self.thumbnailURL = thumbnailURL
        self.scheduledStart = scheduledStart
        self.startedAt = startedAt
        self.viewers = viewers
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        status = try c.decode(LiveStatus.self, forKey: .status)
        kind = (try? c.decodeIfPresent(LiveKind.self, forKey: .kind)) ?? .live
        eventType = try? c.decodeIfPresent(LiveEventType.self, forKey: .eventType)
        channelID = try? c.decodeIfPresent(String.self, forKey: .channelID)
        channelName = try? c.decodeIfPresent(String.self, forKey: .channelName)
        thumbnailURL = try? c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        scheduledStart = try? c.decodeIfPresent(Date.self, forKey: .scheduledStart)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        viewers = try? c.decodeIfPresent(Int.self, forKey: .viewers)
    }
}

/// `GET /api/live-streams/:id/state`. What an older server leaves out is off.
public struct LiveState: Hashable, Sendable, Decodable {
    public struct Chat: Hashable, Sendable, Decodable {
        public var enabled: Bool
        public var replay: Bool

        public init(enabled: Bool = false, replay: Bool = false) {
            self.enabled = enabled
            self.replay = replay
        }
    }

    public var status: LiveStatus
    public var sessionStatus: String?
    public var kind: LiveKind
    public var playbackURL: URL?
    public var vodURL: URL?
    public var startedAt: Date?
    public var scheduledStart: Date?
    /// The video a premiere shows, once it is on or over.
    public var premiereVideoID: String?
    public var durationSeconds: Double?
    public var eventType: LiveEventType?
    public var viewers: Int?
    /// The server's clock when the state was read, in milliseconds.
    public var serverNow: Double?
    public var chat: Chat
    /// Seconds until the server wants this read again; nil when it does not say.
    public var pollAfter: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case status, sessionStatus, kind, startedAt, durationSeconds, eventType, viewers, serverNow, chat, pollAfterMs
        case playbackURL = "playbackUrl"
        case vodURL = "vodUrl"
        case scheduledStart = "scheduledStartTime"
        case premiereVideoID = "premiereVideoId"
    }

    public init(
        status: LiveStatus, sessionStatus: String? = nil, kind: LiveKind = .live, playbackURL: URL? = nil, vodURL: URL? = nil,
        startedAt: Date? = nil, scheduledStart: Date? = nil, premiereVideoID: String? = nil, durationSeconds: Double? = nil,
        eventType: LiveEventType? = nil, viewers: Int? = nil, serverNow: Double? = nil, chat: Chat = Chat(),
        pollAfter: TimeInterval? = nil
    ) {
        self.status = status
        self.sessionStatus = sessionStatus
        self.kind = kind
        self.playbackURL = playbackURL
        self.vodURL = vodURL
        self.startedAt = startedAt
        self.scheduledStart = scheduledStart
        self.premiereVideoID = premiereVideoID
        self.durationSeconds = durationSeconds
        self.eventType = eventType
        self.viewers = viewers
        self.serverNow = serverNow
        self.chat = chat
        self.pollAfter = pollAfter
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(LiveStatus.self, forKey: .status)
        sessionStatus = try? c.decodeIfPresent(String.self, forKey: .sessionStatus)
        kind = (try? c.decodeIfPresent(LiveKind.self, forKey: .kind)) ?? .live
        playbackURL = try? c.decodeIfPresent(URL.self, forKey: .playbackURL)
        vodURL = try? c.decodeIfPresent(URL.self, forKey: .vodURL)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        scheduledStart = try? c.decodeIfPresent(Date.self, forKey: .scheduledStart)
        premiereVideoID = try? c.decodeIfPresent(String.self, forKey: .premiereVideoID)
        durationSeconds = try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        eventType = try? c.decodeIfPresent(LiveEventType.self, forKey: .eventType)
        viewers = try? c.decodeIfPresent(Int.self, forKey: .viewers)
        serverNow = try? c.decodeIfPresent(Double.self, forKey: .serverNow)
        chat = (try? c.decodeIfPresent(Chat.self, forKey: .chat)) ?? Chat()
        pollAfter = c.pollAfter(forKey: .pollAfterMs)
    }
}

/// A state and how far the server's clock is ahead of the device's, in seconds.
public struct TimedLiveState: Hashable, Sendable {
    public var state: LiveState
    public var clockOffset: TimeInterval

    public init(state: LiveState, clockOffset: TimeInterval = 0) {
        self.state = state
        self.clockOffset = clockOffset
    }

    /// The answer's `serverNow` belongs to the middle of the request.
    public init(state: LiveState, sentAt: Date, receivedAt: Date) {
        let middle = (sentAt.timeIntervalSince1970 + receivedAt.timeIntervalSince1970) / 2
        self.init(state: state, clockOffset: state.serverNow.map { $0 / 1000 - middle } ?? 0)
    }
}

public struct LiveChatMessage: Identifiable, Hashable, Sendable, Decodable {
    public enum Role: String, Decodable, Hashable, Sendable { case owner, moderator }

    public var id: String
    public var userID: String?
    public var authorName: String
    public var authorRole: Role?
    public var text: String
    /// Milliseconds from the stream's start.
    public var offsetMs: Int

    enum CodingKeys: String, CodingKey {
        case id, authorName, authorRole, text, offsetMs
        case userID = "userId"
    }

    public init(
        id: String, userID: String? = nil, authorName: String, authorRole: Role? = nil, text: String, offsetMs: Int
    ) {
        self.id = id
        self.userID = userID
        self.authorName = authorName
        self.authorRole = authorRole
        self.text = text
        self.offsetMs = offsetMs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userID = try? c.decodeIfPresent(String.self, forKey: .userID)
        authorName = try c.decode(String.self, forKey: .authorName)
        authorRole = try? c.decodeIfPresent(Role.self, forKey: .authorRole)
        text = try c.decode(String.self, forKey: .text)
        offsetMs = (try? c.decodeIfPresent(Int.self, forKey: .offsetMs)) ?? 0
    }
}

public struct LiveChatPage: Hashable, Sendable, Decodable {
    public var messages: [LiveChatMessage]
    public var pinned: LiveChatMessage?
    /// A replay window holds more than one answer.
    public var truncated: Bool?
    /// Seconds until the server wants the chat read again; nil when it does not say.
    public var pollAfter: TimeInterval?

    enum CodingKeys: String, CodingKey { case messages, pinned, truncated, pollAfterMs }

    public init(
        messages: [LiveChatMessage], pinned: LiveChatMessage? = nil, truncated: Bool? = nil, pollAfter: TimeInterval? = nil
    ) {
        self.messages = messages
        self.pinned = pinned
        self.truncated = truncated
        self.pollAfter = pollAfter
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decode([LiveChatMessage].self, forKey: .messages)
        pinned = try c.decodeIfPresent(LiveChatMessage.self, forKey: .pinned)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated)
        pollAfter = c.pollAfter(forKey: .pollAfterMs)
    }
}

extension KeyedDecodingContainer {
    /// A whole answer is never lost to a bad value here: what is not a number is as if it were absent.
    fileprivate func pollAfter(forKey key: Key) -> TimeInterval? {
        guard let ms = try? decodeIfPresent(Double.self, forKey: key), ms > 0, ms.isFinite else { return nil }
        return ms / 1000
    }
}

/// The server cannot answer now, and says when to ask again (`Retry-After` on a 429 or 503), in seconds.
public struct LiveRefused: Error, Equatable {
    public var retryAfter: TimeInterval

    public init(retryAfter: TimeInterval) { self.retryAfter = retryAfter }

    /// Seconds, or a date: from the answer's own `Date`, so a device's clock that is wrong does not matter.
    init?(_ response: URLResponse, now: Date) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 429 || response.statusCode == 503,
            let text = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces)
        else { return nil }
        if let seconds = Int(text) {
            guard seconds >= 0 else { return nil }
            self.init(retryAfter: TimeInterval(seconds))
        } else if let at = Self.date(text) {
            let sent = response.value(forHTTPHeaderField: "Date").flatMap(Self.date) ?? now
            self.init(retryAfter: max(0, at.timeIntervalSince(sent)))
        } else {
            return nil
        }
    }

    /// The date form of HTTP headers (RFC 9110).
    private static func date(_ text: String) -> Date? {
        // swiftlint:disable:next display_format - an HTTP header, not shown
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: text)
    }
}

public protocol LiveServicing: Sendable {
    /// What viewers are offered (`GET /api/me/features`); everything off when it cannot be read.
    func features() async -> UserFeatures
    func streams(_ status: LiveStatus, event: LiveEventType?) async throws -> [LiveStream]
    func stream(id: String) async throws -> LiveStream
    func state(id: String) async throws -> TimedLiveState
    /// The newest messages.
    func chat(id: String) async throws -> LiveChatPage
    /// The messages of a recording between two moments, at most 60 seconds apart.
    func chatReplay(id: String, fromMs: Int, toMs: Int) async throws -> LiveChatPage
    /// Counts this screen among those watching, and answers how many there are.
    func beat(id: String, viewerID: String, leaving: Bool) async throws -> Int?
}

public struct NativeLiveService: LiveServicing {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let now: @Sendable () -> Date
    private static let listLimit = 50

    public init(baseURL: URL, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.session = session
        self.now = now
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            return try Date.ISO8601FormatStyle().parse(text)
        }
    }

    private struct Envelope<T: Decodable>: Decodable { let result: T }
    private struct StreamBody: Decodable { let stream: LiveStream }
    private struct Viewers: Decodable { let viewers: Int? }
    /// One stream this app cannot read (a newer status) never takes the list with it.
    private struct ListBody: Decodable {
        struct Lenient: Decodable {
            let stream: LiveStream?
            init(from decoder: any Decoder) throws { stream = try? LiveStream(from: decoder) }
        }
        let data: [Lenient]
    }

    private func path(_ id: String, _ tail: String = "") throws -> String {
        guard SafeInput.isSafePathSegment(id) else { throw CoreError.notFound }
        return "/api/live-streams/\(id)\(tail)"
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard let url = SafeInput.resolveSameOrigin(base: baseURL, path: path, query: query) else {
            throw CoreError.notFound
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setAUNClient()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            AUNLog.network.error("GET \(SafeInput.sanitizeLogLine(url.path), privacy: .public) failed: \(status)")
            if let refused = LiveRefused(response, now: now()) { throw refused }
            throw status == 404 ? CoreError.notFound : CoreError.http(status: status)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            AUNLog.network.error("Decoding \(String(describing: type), privacy: .public) failed: \(error)")
            throw CoreError.decoding
        }
    }

    public func features() async -> UserFeatures {
        (try? await get(UserFeatures.self, "/api/me/features")) ?? .none
    }

    public func streams(_ status: LiveStatus, event: LiveEventType?) async throws -> [LiveStream] {
        var query = [
            URLQueryItem(name: "status", value: status.rawValue), URLQueryItem(name: "limit", value: String(Self.listLimit)),
        ]
        if let event { query.append(URLQueryItem(name: "eventType", value: event.rawValue)) }
        return try await get(Envelope<ListBody>.self, "/api/live-streams", query: query).result.data.compactMap(\.stream)
    }

    public func stream(id: String) async throws -> LiveStream {
        try await get(Envelope<StreamBody>.self, try path(id)).result.stream
    }

    public func state(id: String) async throws -> TimedLiveState {
        let sentAt = now()
        let state = try await get(Envelope<LiveState>.self, try path(id, "/state")).result
        return TimedLiveState(state: state, sentAt: sentAt, receivedAt: now())
    }

    public func chat(id: String) async throws -> LiveChatPage {
        try await get(Envelope<LiveChatPage>.self, try path(id, "/chat")).result
    }

    public func chatReplay(id: String, fromMs: Int, toMs: Int) async throws -> LiveChatPage {
        try await get(
            Envelope<LiveChatPage>.self, try path(id, "/chat"),
            query: [URLQueryItem(name: "fromMs", value: String(fromMs)), URLQueryItem(name: "toMs", value: String(toMs))]
        ).result
    }

    public func beat(id: String, viewerID: String, leaving: Bool) async throws -> Int? {
        guard let url = SafeInput.resolveSameOrigin(base: baseURL, path: try path(id, "/viewers")) else {
            throw CoreError.notFound
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setAUNClient()
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["viewerId": viewerID, "leaving": leaving])
        let (data, response) = try await session.data(for: request)
        if let refused = LiveRefused(response, now: now()) { throw refused }
        return (try? decoder.decode(Envelope<Viewers>.self, from: data))?.result.viewers
    }
}

import Foundation

public enum LiveStreamStatus: String, CaseIterable, Codable, Hashable, Sendable {
    case scheduled, live, ended, cancelled
}

public enum LiveStreamKind: String, CaseIterable, Codable, Hashable, Sendable {
    case live, premiere
}

public enum LiveEventType: String, CaseIterable, Codable, Hashable, Sendable {
    case jumuah, taraweeh, conference, halqa
}

public enum LiveChatAuthorRole: String, Codable, Hashable, Sendable {
    case owner, moderator
}

public enum LiveModerationAction: String, Codable, Hashable, Sendable {
    case remove, pin, unpin, approve
    case blockAuthor = "block_author"
}

public enum LiveReportReason: String, CaseIterable, Codable, Hashable, Sendable {
    case spam, harassment, inappropriate, misinformation, other
}

public struct LiveStream: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var title: String
    public var description: String?
    public var status: LiveStreamStatus
    public var kind: LiveStreamKind
    public var premiereVideoID: String?
    public var eventType: LiveEventType?
    public var channelID: String?
    public var channelName: String?
    public var thumbnailURL: URL?
    public var scheduledStartTime: Date?
    public var actualStartTime: Date?
    public var actualEndTime: Date?
    public var playbackURL: URL?
    public var vodURL: URL?
    public var currentViewers: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, kind, eventType, channelName
        case scheduledStartTime, actualStartTime, actualEndTime, currentViewers
        case premiereVideoID = "premiereVideoId"
        case channelID = "channelId"
        case thumbnailURL = "thumbnailUrl"
        case playbackURL = "playbackUrl"
        case vodURL = "vodUrl"
    }

    public init(
        id: String, title: String, description: String? = nil, status: LiveStreamStatus = .scheduled,
        kind: LiveStreamKind = .live, premiereVideoID: String? = nil, eventType: LiveEventType? = nil,
        channelID: String? = nil, channelName: String? = nil, thumbnailURL: URL? = nil,
        scheduledStartTime: Date? = nil, actualStartTime: Date? = nil, actualEndTime: Date? = nil,
        playbackURL: URL? = nil, vodURL: URL? = nil, currentViewers: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.kind = kind
        self.premiereVideoID = premiereVideoID
        self.eventType = eventType
        self.channelID = channelID
        self.channelName = channelName
        self.thumbnailURL = thumbnailURL
        self.scheduledStartTime = scheduledStartTime
        self.actualStartTime = actualStartTime
        self.actualEndTime = actualEndTime
        self.playbackURL = playbackURL
        self.vodURL = vodURL
        self.currentViewers = currentViewers
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        status = (try? c.decode(LiveStreamStatus.self, forKey: .status)) ?? .scheduled
        kind = (try? c.decode(LiveStreamKind.self, forKey: .kind)) ?? .live
        premiereVideoID = try c.decodeIfPresent(String.self, forKey: .premiereVideoID)
        eventType = try? c.decodeIfPresent(LiveEventType.self, forKey: .eventType)
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
        channelName = try c.decodeIfPresent(String.self, forKey: .channelName)
        thumbnailURL = try? c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        scheduledStartTime = try? c.decodeIfPresent(Date.self, forKey: .scheduledStartTime)
        actualStartTime = try? c.decodeIfPresent(Date.self, forKey: .actualStartTime)
        actualEndTime = try? c.decodeIfPresent(Date.self, forKey: .actualEndTime)
        playbackURL = try? c.decodeIfPresent(URL.self, forKey: .playbackURL)
        vodURL = try? c.decodeIfPresent(URL.self, forKey: .vodURL)
        currentViewers = try c.decodeIfPresent(Int.self, forKey: .currentViewers)
    }
}

public struct LiveChatMessage: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var streamID: String
    public var userID: String
    public var authorName: String
    public var authorHandle: String?
    public var authorAvatarURL: URL?
    public var authorRole: LiveChatAuthorRole?
    public var text: String
    public var offsetMs: Int
    public var isPinned: Bool
    public var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, authorName, authorHandle, authorRole, text, offsetMs, isPinned, createdAt
        case streamID = "streamId"
        case userID = "userId"
        case authorAvatarURL = "authorAvatar"
    }

    public init(
        id: String, streamID: String, userID: String, authorName: String, authorHandle: String? = nil,
        authorAvatarURL: URL? = nil, authorRole: LiveChatAuthorRole? = nil, text: String, offsetMs: Int = 0,
        isPinned: Bool = false, createdAt: Date? = nil
    ) {
        self.id = id
        self.streamID = streamID
        self.userID = userID
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarURL = authorAvatarURL
        self.authorRole = authorRole
        self.text = text
        self.offsetMs = offsetMs
        self.isPinned = isPinned
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        streamID = try c.decodeIfPresent(String.self, forKey: .streamID) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName) ?? ""
        authorHandle = try c.decodeIfPresent(String.self, forKey: .authorHandle)
        authorAvatarURL = try? c.decodeIfPresent(URL.self, forKey: .authorAvatarURL)
        authorRole = try? c.decodeIfPresent(LiveChatAuthorRole.self, forKey: .authorRole)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        offsetMs = try c.decodeIfPresent(Int.self, forKey: .offsetMs) ?? 0
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

public struct LiveChatSettings: Hashable, Sendable, Decodable {
    public var enabled: Bool
    public var replayEnabled: Bool
    public var slowModeSeconds: Int
    public var subscribersOnly: Bool
    public var pinnedMessage: LiveChatMessage?

    public init(
        enabled: Bool = false, replayEnabled: Bool = false, slowModeSeconds: Int = 0, subscribersOnly: Bool = false,
        pinnedMessage: LiveChatMessage? = nil
    ) {
        self.enabled = enabled
        self.replayEnabled = replayEnabled
        self.slowModeSeconds = slowModeSeconds
        self.subscribersOnly = subscribersOnly
        self.pinnedMessage = pinnedMessage
    }

    enum CodingKeys: String, CodingKey {
        case enabled, replayEnabled, slowModeSeconds, subscribersOnly, pinnedMessage
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        replayEnabled = try c.decodeIfPresent(Bool.self, forKey: .replayEnabled) ?? false
        slowModeSeconds = try c.decodeIfPresent(Int.self, forKey: .slowModeSeconds) ?? 0
        subscribersOnly = try c.decodeIfPresent(Bool.self, forKey: .subscribersOnly) ?? false
        pinnedMessage = try? c.decodeIfPresent(LiveChatMessage.self, forKey: .pinnedMessage)
    }
}

public struct LiveReminderStatus: Hashable, Sendable, Decodable {
    public var enabled: Bool
    public var count: Int
    public var viewerSubscribed: Bool

    public init(enabled: Bool = false, count: Int = 0, viewerSubscribed: Bool = false) {
        self.enabled = enabled
        self.count = count
        self.viewerSubscribed = viewerSubscribed
    }

    enum CodingKeys: String, CodingKey {
        case enabled, count, viewerSubscribed, subscribed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        viewerSubscribed =
            (try? c.decodeIfPresent(Bool.self, forKey: .viewerSubscribed))
            ?? (try? c.decodeIfPresent(Bool.self, forKey: .subscribed))
            ?? false
    }
}

public struct LiveStreamState: Hashable, Sendable, Decodable {
    public var streamID: String
    public var sessionID: String?
    public var status: LiveStreamStatus
    public var sessionStatus: String?
    public var receiving: Bool
    public var playbackURL: URL?
    public var vodURL: URL?
    public var startedAt: Date?
    public var endedAt: Date?
    public var bitrateKbps: Int?
    public var viewers: Int?
    public var kind: LiveStreamKind
    public var premiereVideoID: String?
    public var eventType: LiveEventType?
    public var scheduledStartTime: Date?
    public var dvrWindowSeconds: Int
    public var chat: LiveChatSettings
    public var reminders: LiveReminderStatus

    enum CodingKeys: String, CodingKey {
        case status, sessionStatus, receiving, startedAt, endedAt, bitrateKbps, viewers
        case kind, eventType, scheduledStartTime, dvrWindowSeconds, chat, reminders
        case streamID = "streamId"
        case sessionID = "sessionId"
        case playbackURL = "playbackUrl"
        case vodURL = "vodUrl"
        case premiereVideoID = "premiereVideoId"
    }

    public init(
        streamID: String, sessionID: String? = nil, status: LiveStreamStatus = .scheduled, sessionStatus: String? = nil,
        receiving: Bool = false, playbackURL: URL? = nil, vodURL: URL? = nil, startedAt: Date? = nil,
        endedAt: Date? = nil, bitrateKbps: Int? = nil, viewers: Int? = nil, kind: LiveStreamKind = .live,
        premiereVideoID: String? = nil, eventType: LiveEventType? = nil, scheduledStartTime: Date? = nil,
        dvrWindowSeconds: Int = 7200, chat: LiveChatSettings = LiveChatSettings(),
        reminders: LiveReminderStatus = LiveReminderStatus()
    ) {
        self.streamID = streamID
        self.sessionID = sessionID
        self.status = status
        self.sessionStatus = sessionStatus
        self.receiving = receiving
        self.playbackURL = playbackURL
        self.vodURL = vodURL
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bitrateKbps = bitrateKbps
        self.viewers = viewers
        self.kind = kind
        self.premiereVideoID = premiereVideoID
        self.eventType = eventType
        self.scheduledStartTime = scheduledStartTime
        self.dvrWindowSeconds = dvrWindowSeconds
        self.chat = chat
        self.reminders = reminders
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try c.decodeIfPresent(String.self, forKey: .streamID) ?? ""
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        status = (try? c.decode(LiveStreamStatus.self, forKey: .status)) ?? .scheduled
        sessionStatus = try c.decodeIfPresent(String.self, forKey: .sessionStatus)
        receiving = try c.decodeIfPresent(Bool.self, forKey: .receiving) ?? false
        playbackURL = try? c.decodeIfPresent(URL.self, forKey: .playbackURL)
        vodURL = try? c.decodeIfPresent(URL.self, forKey: .vodURL)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try? c.decodeIfPresent(Date.self, forKey: .endedAt)
        bitrateKbps = try c.decodeIfPresent(Int.self, forKey: .bitrateKbps)
        viewers = try c.decodeIfPresent(Int.self, forKey: .viewers)
        kind = (try? c.decode(LiveStreamKind.self, forKey: .kind)) ?? .live
        premiereVideoID = try c.decodeIfPresent(String.self, forKey: .premiereVideoID)
        eventType = try? c.decodeIfPresent(LiveEventType.self, forKey: .eventType)
        scheduledStartTime = try? c.decodeIfPresent(Date.self, forKey: .scheduledStartTime)
        dvrWindowSeconds = try c.decodeIfPresent(Int.self, forKey: .dvrWindowSeconds) ?? 7200
        chat = (try? c.decodeIfPresent(LiveChatSettings.self, forKey: .chat)) ?? LiveChatSettings()
        reminders = (try? c.decodeIfPresent(LiveReminderStatus.self, forKey: .reminders)) ?? LiveReminderStatus()
    }
}

public struct LiveChatPage: Hashable, Sendable, Decodable {
    public var messages: [LiveChatMessage]
    public var pinnedMessage: LiveChatMessage?
    public var settings: LiveChatSettings
    public var canModerate: Bool

    public init(
        messages: [LiveChatMessage] = [], pinnedMessage: LiveChatMessage? = nil,
        settings: LiveChatSettings = LiveChatSettings(), canModerate: Bool = false
    ) {
        self.messages = messages
        self.pinnedMessage = pinnedMessage
        self.settings = settings
        self.canModerate = canModerate
    }

    enum CodingKeys: String, CodingKey {
        case messages, pinnedMessage, settings, canModerate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([LiveChatMessage].self, forKey: .messages) ?? []
        pinnedMessage = try? c.decodeIfPresent(LiveChatMessage.self, forKey: .pinnedMessage)
        settings = (try? c.decodeIfPresent(LiveChatSettings.self, forKey: .settings)) ?? LiveChatSettings()
        canModerate = try c.decodeIfPresent(Bool.self, forKey: .canModerate) ?? false
    }
}

/// Stage-1 synchronous live chat filter matching shared-types `checkLiveChatFastFilter`.
public enum LiveChatFastFilter {
    public static let maxLength = 300

    public enum Rejection: String, Equatable, Sendable {
        case empty, tooLong, urlBlocked, spamRepetition
    }

    public static func check(_ text: String, canPostLinks: Bool = false) -> Rejection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > maxLength { return .tooLong }
        if !canPostLinks {
            let lower = trimmed.lowercased()
            if lower.contains("http://") || lower.contains("https://") || lower.contains("www.")
                || lower.contains("t.me/") || lower.contains("wa.me/") || lower.contains("discord.gg/")
            {
                return .urlBlocked
            }
        }
        var run = 1
        var previous: Character?
        for ch in trimmed {
            if ch == previous {
                run += 1
                if run >= 12 { return .spamRepetition }
            } else {
                previous = ch
                run = 1
            }
        }
        return nil
    }
}

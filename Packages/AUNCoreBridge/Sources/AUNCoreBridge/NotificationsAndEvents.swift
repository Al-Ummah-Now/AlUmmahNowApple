import Foundation

/// Platform bell-open mode (`Core#40`).
public enum NotificationMenuOpenMode: String, Codable, Equatable, Sendable {
    case seen
    case read
}

/// Unread vs unseen counts for the header bell (`Core#40`).
public struct NotificationBadge: Equatable, Sendable {
    public var unreadCount: Int
    public var unseenCount: Int
    public var menuOpen: NotificationMenuOpenMode

    public init(unreadCount: Int = 0, unseenCount: Int = 0, menuOpen: NotificationMenuOpenMode = .seen) {
        self.unreadCount = unreadCount
        self.unseenCount = unseenCount
        self.menuOpen = menuOpen
    }
}

/// One in-app notification row.
public struct NotificationEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var category: String
    public var notificationType: String
    public var notificationKey: String
    public var title: String
    public var params: [String: String]
    public var readAt: Date?
    public var createdAt: Date

    public init(
        id: String, category: String, notificationType: String, notificationKey: String, title: String,
        params: [String: String] = [:], readAt: Date? = nil, createdAt: Date
    ) {
        self.id = id
        self.category = category
        self.notificationType = notificationType
        self.notificationKey = notificationKey
        self.title = title
        self.params = params
        self.readAt = readAt
        self.createdAt = createdAt
    }

    public var isRead: Bool { readAt != nil }
}

/// Local-day prayer quiet interval (`0..1439` minutes from midnight; zero GPS coordinates leave the device).
public struct PrayerQuietWindow: Codable, Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

/// Daily quiet-hours schedule and optional prayer-time quiet windows (`E22-D6`).
public struct NotificationQuietHours: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var timezone: String
    public var startMinute: Int
    public var endMinute: Int
    public var prayerQuietEnabled: Bool
    public var prayerWindows: [PrayerQuietWindow]

    public init(
        enabled: Bool = false,
        timezone: String = TimeZone.current.identifier,
        startMinute: Int = 1320,
        endMinute: Int = 360,
        prayerQuietEnabled: Bool = false,
        prayerWindows: [PrayerQuietWindow] = []
    ) {
        self.enabled = enabled
        self.timezone = timezone
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.prayerQuietEnabled = prayerQuietEnabled
        self.prayerWindows = prayerWindows
    }
}

/// One scheduled or live online event from `GET /api/events` (`E22-D7`).
public struct CalendarEvent: Identifiable, Codable, Equatable, Sendable {
    public var streamId: String
    public var channelId: String
    public var channelName: String
    public var channelNameAr: String?
    public var channelHandle: String?
    public var title: String
    public var description: String?
    public var kind: String
    public var eventType: String?
    public var status: String
    public var scheduledStartAt: String?
    public var startedAt: String?
    public var reminderCount: Int
    public var viewerReminded: Bool
    public var watchPath: String

    public var id: String { streamId }

    public init(
        streamId: String, channelId: String, channelName: String, channelNameAr: String? = nil,
        channelHandle: String? = nil, title: String, description: String? = nil, kind: String = "live",
        eventType: String? = nil, status: String = "scheduled", scheduledStartAt: String? = nil,
        startedAt: String? = nil, reminderCount: Int = 0, viewerReminded: Bool = false, watchPath: String
    ) {
        self.streamId = streamId
        self.channelId = channelId
        self.channelName = channelName
        self.channelNameAr = channelNameAr
        self.channelHandle = channelHandle
        self.title = title
        self.description = description
        self.kind = kind
        self.eventType = eventType
        self.status = status
        self.scheduledStartAt = scheduledStartAt
        self.startedAt = startedAt
        self.reminderCount = reminderCount
        self.viewerReminded = viewerReminded
        self.watchPath = watchPath
    }

    public func displayChannelName(_ language: AppLanguage) -> String {
        if language == .ar, let ar = channelNameAr, !ar.isEmpty { return ar }
        return channelName
    }
}

/// Notification center & quiet-hours protocol (`CoreBridge`).
public protocol NotificationsServicing: Sendable {
    func badge() async throws -> NotificationBadge
    func list(limit: Int) async throws -> ([NotificationEntry], NotificationBadge)
    func markSeen(ids: [String]) async throws -> (NotificationBadge, [String])
    func markAllRead() async throws -> NotificationBadge
    func quietHours() async throws -> NotificationQuietHours
    func updateQuietHours(_ quietHours: NotificationQuietHours) async throws -> NotificationQuietHours
}

/// Online Event Calendar & feature-flag protocol (`CoreBridge`).
public protocol EventsServicing: Sendable {
    func viewerFeatures() async throws -> UserFeatures
    func upcomingEvents(eventType: String?) async throws -> [CalendarEvent]
}

/// Device push registration payload (`PUT /api/devices/:installId`).
public struct AppPushRegistration: Equatable, Sendable {
    public var app: String
    public var installID: String
    public var token: String
    public var platform: String
    public var locale: String
    public var appVersion: String

    public init(
        app: String, installID: String, token: String, platform: String, locale: String, appVersion: String = "1.0"
    ) {
        self.app = app
        self.installID = installID
        self.token = token
        self.platform = platform
        self.locale = locale
        self.appVersion = appVersion
    }
}

/// Native APNs device registration for Viewer and Studio (`PUT / DELETE /api/devices/:installId`).
public protocol AppPushRegistering: Sendable {
    func register(_ registration: AppPushRegistration) async throws
    func unregister(installID: String) async throws
}

private struct APITransport: Sendable {
    let baseURL: URL
    let session: URLSession

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], bearerToken: String? = nil) async throws -> T {
        let data = try await send(method: "GET", path: path, query: query, bearerToken: bearerToken)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CoreError.decoding
        }
    }

    func send(
        method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil, bearerToken: String? = nil
    ) async throws -> Data {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw CoreError.notFound
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CoreError.notFound }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setAUNClient()
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) {
            throw CoreError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let refusal = Refusal.parse(data) { throw CoreError.refused(refusal) }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                (obj["code"] as? String) == Refusal.featureOff || (obj["error"] as? String) == Refusal.featureOff
            {
                throw CoreError.featureOff
            }
            switch status {
            case 401: throw CoreError.signInRequired
            case 402: throw CoreError.http(status: 402)
            case 403: throw CoreError.forbidden
            case 404: throw CoreError.notFound
            default: throw CoreError.http(status: status)
            }
        }
        return data
    }
}

public struct NativeNotificationsService: NotificationsServicing {
    private let client: APITransport
    private let auth: any AuthSessionProviding

    public init(baseURL: URL, auth: any AuthSessionProviding, session: URLSession = .shared) {
        self.client = APITransport(baseURL: baseURL, session: session)
        self.auth = auth
    }

    private struct CountsBody: Decodable {
        var unreadCount: Int?
        var unseenCount: Int?
        var menuOpen: NotificationMenuOpenMode?
        var readIds: [String]?
        func toBadge() -> NotificationBadge {
            let unread = unreadCount ?? 0
            return NotificationBadge(unreadCount: unread, unseenCount: unseenCount ?? unread, menuOpen: menuOpen ?? .seen)
        }
    }

    private struct ResultEnvelope<T: Decodable>: Decodable { var result: T }

    private struct ParamValue: Decodable {
        var stringValue: String
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                stringValue = s
            } else if let n = try? c.decode(Int.self) {
                stringValue = String(n)
            } else if let d = try? c.decode(Double.self) {
                stringValue = String(d)
            } else if let b = try? c.decode(Bool.self) {
                stringValue = b ? "true" : "false"
            } else {
                stringValue = ""
            }
        }
    }

    private struct RawItem: Decodable {
        var id: String
        var category: String
        var notificationType: String
        var notificationKey: String
        var params: [String: ParamValue]?
        var readAt: Double?
        var createdAt: Double
    }

    private struct ListResult: Decodable {
        var items: [RawItem]
        var unreadCount: Int?
        var unseenCount: Int?
        var menuOpen: NotificationMenuOpenMode?
    }

    private struct SettingsResult: Decodable {
        var quietHours: NotificationQuietHours?
    }

    public func badge() async throws -> NotificationBadge {
        guard let token = try await auth.accessToken() else { return NotificationBadge() }
        let env: ResultEnvelope<CountsBody> = try await client.get("/api/notifications/unread-count", bearerToken: token)
        return env.result.toBadge()
    }

    public func list(limit: Int = 20) async throws -> ([NotificationEntry], NotificationBadge) {
        guard let token = try await auth.accessToken() else { return ([], NotificationBadge()) }
        let env: ResultEnvelope<ListResult> = try await client.get(
            "/api/notifications", query: [URLQueryItem(name: "limit", value: String(max(1, min(50, limit))))],
            bearerToken: token)
        let unread = env.result.unreadCount ?? 0
        let badge = NotificationBadge(
            unreadCount: unread, unseenCount: env.result.unseenCount ?? unread, menuOpen: env.result.menuOpen ?? .seen)
        let entries = env.result.items.map { item in
            let stringParams = (item.params ?? [:]).mapValues(\.stringValue)
            let title = stringParams["videoTitle"] ?? stringParams["streamTitle"] ?? stringParams["channelName"] ?? ""
            return NotificationEntry(
                id: item.id, category: item.category, notificationType: item.notificationType,
                notificationKey: item.notificationKey, title: title, params: stringParams,
                readAt: item.readAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                createdAt: Date(timeIntervalSince1970: item.createdAt / 1000))
        }
        return (entries, badge)
    }

    public func markSeen(ids: [String]) async throws -> (NotificationBadge, [String]) {
        guard let token = try await auth.accessToken() else { return (NotificationBadge(), []) }
        let body = try JSONSerialization.data(withJSONObject: ["ids": Array(ids.prefix(100))])
        let data = try await client.send(method: "POST", path: "/api/notifications/seen", body: body, bearerToken: token)
        let env = try JSONDecoder().decode(ResultEnvelope<CountsBody>.self, from: data)
        return (env.result.toBadge(), env.result.readIds ?? [])
    }

    public func markAllRead() async throws -> NotificationBadge {
        guard let token = try await auth.accessToken() else { return NotificationBadge() }
        let data = try await client.send(method: "POST", path: "/api/notifications/read-all", bearerToken: token)
        let env = try JSONDecoder().decode(ResultEnvelope<CountsBody>.self, from: data)
        return env.result.toBadge()
    }

    public func quietHours() async throws -> NotificationQuietHours {
        guard let token = try await auth.accessToken() else { return NotificationQuietHours() }
        let env: ResultEnvelope<SettingsResult> = try await client.get("/api/notifications/settings", bearerToken: token)
        return env.result.quietHours ?? NotificationQuietHours()
    }

    public func updateQuietHours(_ quietHours: NotificationQuietHours) async throws -> NotificationQuietHours {
        guard let token = try await auth.accessToken() else { throw CoreError.signInRequired }
        let payload = try JSONEncoder().encode(["quietHours": quietHours])
        let data = try await client.send(method: "PUT", path: "/api/notifications/settings", body: payload, bearerToken: token)
        let env = try JSONDecoder().decode(ResultEnvelope<SettingsResult>.self, from: data)
        return env.result.quietHours ?? quietHours
    }
}

public struct NativeEventsService: EventsServicing {
    private let client: APITransport
    private let auth: any AuthSessionProviding

    public init(baseURL: URL, auth: any AuthSessionProviding, session: URLSession = .shared) {
        self.client = APITransport(baseURL: baseURL, session: session)
        self.auth = auth
    }

    private struct EventsEnvelope: Decodable {
        struct Page: Decodable { var items: [CalendarEvent] }
        var result: Page
    }

    public func viewerFeatures() async throws -> UserFeatures {
        let token = try? await auth.accessToken()
        return try await client.get("/api/me/features", bearerToken: token)
    }

    public func upcomingEvents(eventType: String? = nil) async throws -> [CalendarEvent] {
        let token = try? await auth.accessToken()
        var query = [URLQueryItem(name: "limit", value: "24")]
        if let eventType, !eventType.isEmpty {
            query.append(URLQueryItem(name: "eventType", value: eventType))
        }
        let env: EventsEnvelope = try await client.get("/api/events", query: query, bearerToken: token)
        return env.result.items
    }
}

private struct AccountSessionAdapter: AuthSessionProviding {
    let accounts: any AccountServicing
    func accessToken() async throws -> String? { try await accounts.accessToken() }
}

public struct NativeAppPushService: AppPushRegistering {
    private let client: APITransport
    private let auth: any AuthSessionProviding

    public init(baseURL: URL, auth: any AuthSessionProviding, session: URLSession = .shared) {
        self.client = APITransport(baseURL: baseURL, session: session)
        self.auth = auth
    }

    public init(baseURL: URL, accounts: any AccountServicing, session: URLSession = .shared) {
        self.client = APITransport(baseURL: baseURL, session: session)
        self.auth = AccountSessionAdapter(accounts: accounts)
    }

    public func register(_ reg: AppPushRegistration) async throws {
        guard let bearer = try await auth.accessToken() else { return }
        let body = try JSONSerialization.data(withJSONObject: [
            "app": reg.app, "provider": "apns", "platform": reg.platform,
            "token": reg.token, "locale": reg.locale, "appVersion": reg.appVersion,
        ])
        _ = try await client.send(method: "PUT", path: "/api/devices/\(reg.installID)", body: body, bearerToken: bearer)
    }

    public func unregister(installID: String) async throws {
        guard let bearer = try await auth.accessToken() else { return }
        _ = try await client.send(method: "DELETE", path: "/api/devices/\(installID)", bearerToken: bearer)
    }
}

public actor FixtureNotificationsService: NotificationsServicing {
    private var storedQuiet = NotificationQuietHours(
        enabled: true, timezone: "Asia/Riyadh", startMinute: 1320, endMinute: 360, prayerQuietEnabled: true,
        prayerWindows: [PrayerQuietWindow(startMinute: 300, endMinute: 325)])
    private var unseen: Int

    public init(unseenCount: Int = 2) { self.unseen = unseenCount }

    public func badge() async throws -> NotificationBadge {
        NotificationBadge(unreadCount: max(unseen, 1), unseenCount: unseen, menuOpen: .seen)
    }

    public func list(limit: Int) async throws -> ([NotificationEntry], NotificationBadge) {
        let now = Date(timeIntervalSince1970: 1_795_450_000)
        let items = [
            NotificationEntry(
                id: "notif-1", category: "live", notificationType: "stream", notificationKey: "liveStarted",
                title: "Al Ummah Now", createdAt: now)
        ]
        return (Array(items.prefix(limit)), NotificationBadge(unreadCount: 1, unseenCount: unseen, menuOpen: .seen))
    }

    public func markSeen(ids: [String]) async throws -> (NotificationBadge, [String]) {
        unseen = 0
        return (NotificationBadge(unreadCount: 1, unseenCount: 0, menuOpen: .seen), [])
    }

    public func markAllRead() async throws -> NotificationBadge {
        unseen = 0
        return NotificationBadge(unreadCount: 0, unseenCount: 0, menuOpen: .seen)
    }

    public func quietHours() async throws -> NotificationQuietHours { storedQuiet }

    public func updateQuietHours(_ quietHours: NotificationQuietHours) async throws -> NotificationQuietHours {
        storedQuiet = quietHours
        return storedQuiet
    }
}

public struct FixtureEventsService: EventsServicing {
    public var eventCalendarEnabled: Bool

    public init(eventCalendarEnabled: Bool = false) {
        self.eventCalendarEnabled = eventCalendarEnabled
    }

    public func viewerFeatures() async throws -> UserFeatures {
        eventCalendarEnabled ? UserFeatures(on: [.eventCalendar, .live]) : .none
    }

    public func upcomingEvents(eventType: String?) async throws -> [CalendarEvent] {
        guard eventCalendarEnabled else { throw CoreError.featureOff }
        let items = [
            CalendarEvent(
                streamId: "str_halqa_1", channelId: "ch_manar", channelName: "Al-Manar",
                channelNameAr: "المنار", channelHandle: "almanar",
                title: "Weekly Tafsir Halqa", kind: "live", eventType: "halqa",
                status: "scheduled", scheduledStartAt: "2026-11-28T19:00:00Z", watchPath: "/live/str_halqa_1")
        ]
        if let eventType, !eventType.isEmpty {
            return items.filter { $0.eventType == eventType }
        }
        return items
    }
}

public struct NoopAppPushService: AppPushRegistering {
    public init() {}
    public func register(_ registration: AppPushRegistration) async throws {}
    public func unregister(installID: String) async throws {}
}

#if os(iOS) || os(macOS)
    import Observation
    @preconcurrency import UserNotifications
    #if os(iOS)
        import UIKit
    #endif

    /// APNs registration for Viewer and Studio (`app: "viewer" | "studio"`), reusing the `AdminPush` pattern.
    @MainActor @Observable
    public final class AppPushController {
        public let appRole: String
        public let installID: String
        private let service: any AppPushRegistering
        private let center: UNUserNotificationCenter?
        private var hexToken: String?

        public init(
            appRole: String = "viewer",
            installID: String? = nil,
            service: any AppPushRegistering,
            center: UNUserNotificationCenter? = nil
        ) {
            self.appRole = appRole
            let key = "AUNPushInstallID.\(appRole)"
            if let installID {
                self.installID = installID
            } else if let saved = UserDefaults.standard.string(forKey: key) {
                self.installID = saved
            } else {
                let generated = "inst_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                UserDefaults.standard.set(generated, forKey: key)
                self.installID = generated
            }
            self.service = service
            self.center = center
        }

        // swiftlint:disable display_format
        public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        // swiftlint:enable display_format

        public func requestAuthorization() async -> Bool {
            guard let center else { return false }
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                AUNLog.network.error("Notification authorization failed: \(error)")
                return false
            }
        }

        public func didRegister(deviceToken: Data, language: AppLanguage) {
            hexToken = Self.hex(deviceToken)
            Task { await syncRegistration(language: language) }
        }

        public func syncRegistration(language: AppLanguage) async {
            guard let hexToken else { return }
            #if os(macOS)
                let platform = "macos"
            #else
                let platform =
                    ProcessInfo.processInfo.isiOSAppOnMac
                    ? "macos" : (UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios")
            #endif
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            do {
                try await service.register(
                    AppPushRegistration(
                        app: appRole, installID: installID, token: hexToken, platform: platform,
                        locale: language.rawValue, appVersion: version))
            } catch {
                AUNLog.network.error("Device push registration failed: \(error)")
            }
        }

        public func unregisterOnSignOut() async {
            do {
                try await service.unregister(installID: installID)
            } catch {
                AUNLog.network.error("Device push unregister failed: \(error)")
            }
            center?.removeAllDeliveredNotifications()
        }
    }
#endif

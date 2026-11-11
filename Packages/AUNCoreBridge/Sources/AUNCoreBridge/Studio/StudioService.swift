import Foundation

/// Creator Studio calls to api-videos, the same routes the web Studio uses. Every call acts as the active account.
public protocol StudioServicing: Sendable {
    /// Channels the person owns or helps run, owned first (`GET /api/channels/access`).
    func channels() async throws -> [StudioChannel]
    /// A channel's playlists, private ones included for its owner.
    func playlists(channelID: String) async throws -> [StudioPlaylist]

    // MARK: Upload (initiate → TUS through the api-videos proxy → complete)
    func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket
    /// A new TUS session for an unfinished upload (`GET /api/videos/upload/resume/:id`).
    func resumeUpload(videoID: String, channelID: String) async throws -> UploadTicket
    func completeUpload(videoID: String, fileSize: Int64, channelID: String) async throws
    /// The TUS endpoint and the headers every TUS request needs (a fresh bearer token).
    func tusEndpoint() async throws -> (url: URL, headers: [String: String])
    /// Sets the language, which initiate does not take.
    func setLanguage(_ language: VideoLanguage, videoID: String, channelID: String) async throws
    /// Queues the new video for these playlists, in batch order.
    func addToPlaylists(_ playlistIDs: [String], videoID: String, orderKey: String, channelID: String) async throws
    func schedule(videoID: String, at date: Date, timeZone: TimeZone, channelID: String) async throws

    // MARK: Content (the web Studio's Videos tab)
    func content(channelID: String, query: ContentQuery, cursor: String?) async throws -> ContentPage
    func contentCounts(channelID: String) async throws -> ContentCounts
    func updateVideo(_ id: String, _ edit: VideoEdit, channelID: String) async throws
    /// Soft delete: hidden at once, restorable for 30 days from Recently deleted.
    /// `bulk-delete` and `bulk-update` take the `channelId` header, as the web sends it (bulk-delete requires it).
    func deleteVideos(_ ids: [String], channelID: String) async throws -> BulkResult
    func bulkUpdate(_ ids: [String], _ changes: BulkChanges, channelID: String) async throws -> BulkResult
    func bulkSchedule(_ ids: [String], startAt: Date, intervalMinutes: Int, timeZone: TimeZone) async throws -> BulkResult
    func addToPlaylist(_ playlistID: String, videoIDs: [String], channelID: String) async throws
    func deletedVideos(channelID: String, cursor: String?) async throws -> (items: [DeletedVideo], cursor: String?)
    func restoreVideos(_ ids: [String]) async throws -> BulkResult
    /// "Delete permanently": queued for the next hourly cleanup.
    func purgeVideos(_ ids: [String]) async throws -> BulkResult

    // MARK: Analytics
    func channelStats(channelID: String, period: DateInterval) async throws -> ChannelStats
    func videoStats(videoID: String, period: DateInterval) async throws -> VideoStats
}

/// api-videos over URLSession with the active account's bearer token.
public struct NativeStudioService: StudioServicing {
    let client: StudioHTTPClient

    public init(baseURL: URL, accounts: any AccountServicing, session: URLSession = .shared) {
        client = StudioHTTPClient(baseURL: baseURL, accounts: accounts, session: session)
    }

    struct DataEnvelope<T: Decodable>: Decodable { let data: T }

    struct ResultEnvelope<T: Decodable>: Decodable { let result: T }
    struct PlaylistPage: Decodable {
        let data: [StudioPlaylist]
        let cursor: String?
    }

    public func channels() async throws -> [StudioChannel] {
        try await client.send(.get, "/api/channels/access", as: DataEnvelope<[StudioChannel]>.self).data
    }

    public func playlists(channelID: String) async throws -> [StudioPlaylist] {
        var all: [StudioPlaylist] = []
        var cursor: String?
        repeat {
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page = try await client.send(
                .get, "/api/channels/\(channelID)/playlists", query: query, channelID: channelID, as: PlaylistPage.self)
            all += page.data
            // The last page has `"cursor": ""`; sending `cursor=` back is a 400.
            cursor = page.data.isEmpty || (page.cursor ?? "").isEmpty ? nil : page.cursor
        } while cursor != nil && all.count < 1000
        return all
    }

    public func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
        try await client.send(
            .post, "/api/videos/upload/initiate", channelID: channelID, body: upload,
            as: ResultEnvelope<UploadTicket>.self
        ).result
    }

    public func resumeUpload(videoID: String, channelID: String) async throws -> UploadTicket {
        try await client.send(
            .get, "/api/videos/upload/resume/\(videoID)", channelID: channelID, as: ResultEnvelope<UploadTicket>.self
        ).result
    }

    private struct Complete: Encodable {
        let videoId: String
        let fileSize: Int64
    }

    public func completeUpload(videoID: String, fileSize: Int64, channelID: String) async throws {
        try await client.sendRaw(
            .post, "/api/videos/upload/complete", channelID: channelID, body: Complete(videoId: videoID, fileSize: fileSize))
    }

    public func tusEndpoint() async throws -> (url: URL, headers: [String: String]) {
        guard let token = try await client.accounts.accessToken() else { throw CoreError.signInRequired }
        return (client.baseURL.appending(path: "/api/videos/tus"), ["Authorization": "Bearer \(token)"])
    }

    public func setLanguage(_ language: VideoLanguage, videoID: String, channelID: String) async throws {
        try await client.sendRaw(.put, "/api/videos/\(videoID)", channelID: channelID, body: ["language": language.rawValue])
    }

    private struct PlaylistAdds: Encodable {
        let videoId: String
        let playlistIds: [String]
        let orderKey: String
    }

    public func addToPlaylists(_ playlistIDs: [String], videoID: String, orderKey: String, channelID: String) async throws {
        guard !playlistIDs.isEmpty else { return }
        try await client.sendRaw(
            .post, "/api/playlists/upload-adds", channelID: channelID,
            body: PlaylistAdds(videoId: videoID, playlistIds: playlistIDs, orderKey: orderKey))
    }

    private struct Schedule: Encodable {
        let scheduledPublishDate: Date
        let timezone: String
    }

    public func schedule(videoID: String, at date: Date, timeZone: TimeZone, channelID: String) async throws {
        try await client.sendRaw(
            .post, "/api/videos/\(videoID)/schedule", channelID: channelID,
            body: Schedule(scheduledPublishDate: date, timezone: timeZone.identifier))
    }

    // MARK: Content

    struct Page<T: Decodable>: Decodable {
        let items: [T]
        let cursor: String?
    }

    /// An empty cursor means the last page, as for playlists.
    static func nextCursor(_ cursor: String?) -> String? { (cursor ?? "").isEmpty ? nil : cursor }

    public func content(channelID: String, query: ContentQuery, cursor: String?) async throws -> ContentPage {
        var items = [
            URLQueryItem(name: "status", value: query.status.rawValue), URLQueryItem(name: "sort", value: query.sort.rawValue),
            URLQueryItem(name: "limit", value: String(query.limit)),
        ]
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { items.append(URLQueryItem(name: "q", value: String(text.prefix(200)))) }
        if query.visibility != .all { items.append(URLQueryItem(name: "visibility", value: query.visibility.rawValue)) }
        if let cursor = Self.nextCursor(cursor) { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page = try await client.send(
            .get, "/api/channels/\(channelID)/content", query: items, channelID: channelID,
            as: ResultEnvelope<Page<StudioVideo>>.self
        ).result
        return ContentPage(items: page.items, cursor: Self.nextCursor(page.cursor))
    }

    private struct Counts: Decodable { let counts: [String: Int] }

    public func contentCounts(channelID: String) async throws -> ContentCounts {
        let counts = try await client.send(
            .get, "/api/channels/\(channelID)/content/summary", channelID: channelID, as: ResultEnvelope<Counts>.self
        ).result.counts
        return Dictionary(
            uniqueKeysWithValues: counts.compactMap { key, value in StudioStatus(rawValue: key).map { ($0, value) } })
    }

    public func updateVideo(_ id: String, _ edit: VideoEdit, channelID: String) async throws {
        try await client.sendRaw(.put, "/api/videos/\(id)", channelID: channelID, body: edit)
    }

    private struct BulkBody: Decodable {
        struct Item: Decodable {
            let videoId: String
            let success: Bool
            let error: String?
        }
        let results: [Item]
    }

    private struct IDs: Encodable { let videoIds: [String] }

    /// Restore, purge and schedule check each video's own channel and take no `channelId` header, as on the web.
    private func bulk(_ path: String, _ body: some Encodable, channelID: String? = nil) async throws -> BulkResult {
        let reply = try await client.send(.post, path, channelID: channelID, body: body, as: BulkBody.self)
        return BulkResult(items: reply.results.map { .init(videoID: $0.videoId, success: $0.success, error: $0.error) })
    }

    public func deleteVideos(_ ids: [String], channelID: String) async throws -> BulkResult {
        try await bulk("/api/videos/bulk-delete", IDs(videoIds: ids), channelID: channelID)
    }

    private struct BulkUpdate: Encodable {
        let videoIds: [String]
        let changes: BulkChanges
    }

    public func bulkUpdate(_ ids: [String], _ changes: BulkChanges, channelID: String) async throws -> BulkResult {
        try await bulk("/api/videos/bulk-update", BulkUpdate(videoIds: ids, changes: changes), channelID: channelID)
    }

    private struct BulkSchedule: Encodable {
        let videoIds: [String]
        let startAt: Date
        let intervalMinutes: Int
        let timezone: String
    }

    public func bulkSchedule(_ ids: [String], startAt: Date, intervalMinutes: Int, timeZone: TimeZone) async throws
        -> BulkResult
    {
        try await bulk(
            "/api/videos/bulk-schedule",
            BulkSchedule(videoIds: ids, startAt: startAt, intervalMinutes: intervalMinutes, timezone: timeZone.identifier))
    }

    public func addToPlaylist(_ playlistID: String, videoIDs: [String], channelID: String) async throws {
        try await client.sendRaw(
            .post, "/api/playlists/\(playlistID)/videos/bulk", channelID: channelID, body: IDs(videoIds: videoIDs))
    }

    public func deletedVideos(channelID: String, cursor: String?) async throws -> (items: [DeletedVideo], cursor: String?) {
        var query: [URLQueryItem] = []
        if let cursor = Self.nextCursor(cursor) { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page = try await client.send(
            .get, "/api/channels/\(channelID)/content/deleted", query: query, channelID: channelID,
            as: ResultEnvelope<Page<DeletedVideo>>.self
        ).result
        return (page.items, Self.nextCursor(page.cursor))
    }

    public func restoreVideos(_ ids: [String]) async throws -> BulkResult {
        try await bulk("/api/videos/bulk-restore", IDs(videoIds: ids))
    }

    public func purgeVideos(_ ids: [String]) async throws -> BulkResult {
        try await bulk("/api/videos/bulk-purge", IDs(videoIds: ids))
    }

    // MARK: Analytics (raw objects, no envelope)

    private func range(_ period: DateInterval) -> [URLQueryItem] {
        [
            URLQueryItem(name: "dateFrom", value: period.start.ISO8601Format()),
            URLQueryItem(name: "dateTo", value: period.end.ISO8601Format()),
        ]
    }

    public func channelStats(channelID: String, period: DateInterval) async throws -> ChannelStats {
        try await client.send(.get, "/api/analytics/channels/\(channelID)", query: range(period), as: ChannelStats.self)
    }

    public func videoStats(videoID: String, period: DateInterval) async throws -> VideoStats {
        try await client.send(.get, "/api/analytics/videos/\(videoID)", query: range(period), as: VideoStats.self)
    }
}

/// Requests with `Authorization: Bearer`, the optional `channelId` header and the server's error body.
struct StudioHTTPClient: Sendable {
    enum Method: String { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

    let baseURL: URL
    let accounts: any AccountServicing
    let session: URLSession

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let millis = try? container.decode(Double.self) { return Date(timeIntervalSince1970: millis / 1000) }
            let text = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            return try Date.ISO8601FormatStyle().parse(text)
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            // UTC with a Z, as the server's ISO date-time validation expects.
            try container.encode(
                date.ISO8601Format(
                    .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)))
        }
        return encoder
    }()

    private struct ErrorBody: Decodable {
        let error: String?
        let code: String?
    }

    func request(
        _ method: Method, _ path: String, query: [URLQueryItem] = [], channelID: String? = nil, body: Data? = nil
    ) async throws -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw CoreError.notFound }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let token = try await accounts.accessToken() else { throw CoreError.signInRequired }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let channelID { request.setValue(channelID, forHTTPHeaderField: "channelId") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func send<T: Decodable>(
        _ method: Method, _ path: String, query: [URLQueryItem] = [], channelID: String? = nil, body: (any Encodable)? = nil,
        as type: T.Type
    ) async throws -> T {
        let data = try await sendRaw(method, path, query: query, channelID: channelID, body: body)
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            AUNLog.network.error("Decoding \(path, privacy: .public) failed: \(error)")
            throw CoreError.decoding
        }
    }

    @discardableResult
    func sendRaw(
        _ method: Method, _ path: String, query: [URLQueryItem] = [], channelID: String? = nil, body: (any Encodable)? = nil
    ) async throws -> Data {
        let encoded = try body.map { try Self.encoder.encode($0) }
        let request = try await request(method, path, query: query, channelID: channelID, body: encoded)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost].contains(error.code) {
            throw CoreError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? Self.decoder.decode(ErrorBody.self, from: data)
            AUNLog.network.error(
                "\(method.rawValue, privacy: .public) \(path, privacy: .public) failed: \(status) \(body?.code ?? "", privacy: .public)"
            )
            switch status {
            case 401: throw CoreError.signInRequired
            case 403: throw CoreError.forbidden
            case 404: throw CoreError.notFound
            case 400, 422: throw CoreError.invalid(body?.error ?? "")
            default: throw CoreError.http(status: status)
            }
        }
        return data
    }
}

/// Videos that fixture actions change, shared by every copy of one `FixtureStudioService`.
actor FixtureContentStore {
    var videos: [StudioVideo]
    var deleted: [DeletedVideo] = []

    init() {
        let titles: [(String, String, StudioStatus, Bool)] = [
            ("Tafsir of Surah Al-Kahf, part 1", "تفسير سورة الكهف، الجزء الأول", .published, true),
            ("Tafsir of Surah Al-Kahf, part 2", "تفسير سورة الكهف، الجزء الثاني", .published, true),
            ("Friday khutbah: patience", "خطبة الجمعة: الصبر", .published, false),
            ("Seerah lesson 4", "درس السيرة الرابع", .scheduled, false),
            ("Fiqh of fasting (draft)", "فقه الصيام (مسودة)", .drafts, false),
        ]
        videos = titles.enumerated().map { index, item in
            StudioVideo(
                id: "fixture-content-\(index + 1)", title: item.0, titleLocalized: LocalizedText(en: item.0, ar: item.1),
                description: "", channelID: "fixture-channel", isPublic: item.3, isDraft: item.2 == .drafts,
                tags: index < 2 ? ["tafsir"] : [], category: index < 2 ? VideoCategory.quranTafsir.rawValue : nil,
                durationSeconds: Double(600 + index * 120), views: 1500 - index * 200, likes: 40 - index, comments: 5,
                dateCreated: Date(timeIntervalSince1970: 1_794_000_000 - Double(index) * 86_400), studioStatus: item.2,
                scheduledPublishDate: item.2 == .scheduled ? Date(timeIntervalSince1970: 1_800_000_000) : nil)
        }
    }

    func page(_ query: ContentQuery) -> [StudioVideo] {
        let text = query.text.lowercased()
        return videos.filter { video in
            video.studioStatus == query.status
                && (text.isEmpty || video.title.lowercased().contains(text)
                    || (video.titleLocalized?.ar ?? "").contains(query.text))
        }
    }

    func counts() -> ContentCounts {
        Dictionary(grouping: videos, by: { $0.studioStatus ?? .published }).mapValues(\.count)
    }

    func apply(_ ids: [String], _ change: (inout StudioVideo) -> Void) -> BulkResult {
        BulkResult(
            items: ids.map { id in
                guard let index = videos.firstIndex(where: { $0.id == id }) else {
                    return .init(videoID: id, success: false, error: "Not found")
                }
                change(&videos[index])
                return .init(videoID: id, success: true)
            })
    }

    func delete(_ ids: [String]) -> BulkResult {
        let removed = videos.filter { ids.contains($0.id) }
        videos.removeAll { ids.contains($0.id) }
        deleted += removed.map {
            DeletedVideo(id: $0.id, title: $0.title, deletedAt: Date(), purgeAfter: Date().addingTimeInterval(30 * 86_400))
        }
        return BulkResult(items: ids.map { id in .init(videoID: id, success: removed.contains { $0.id == id }) })
    }

    func restore(_ ids: [String], from original: [StudioVideo]) -> BulkResult {
        let back = deleted.filter { ids.contains($0.id) }
        deleted.removeAll { ids.contains($0.id) }
        videos += original.filter { video in back.contains { $0.id == video.id } }
        return BulkResult(items: ids.map { id in .init(videoID: id, success: back.contains { $0.id == id }) })
    }

    func purge(_ ids: [String]) -> BulkResult {
        for index in deleted.indices where ids.contains(deleted[index].id) { deleted[index].status = .queued }
        return BulkResult(items: ids.map { .init(videoID: $0, success: true) })
    }
}

/// Bilingual channels and videos for UI tests, snapshots and previews.
public struct FixtureStudioService: StudioServicing {
    let store = FixtureContentStore()
    private let original = FixtureContentStore()

    public init() {}

    public static let channels: [StudioChannel] = [
        StudioChannel(
            id: "fixture-channel", name: "Al Ummah Now", nameLocalized: LocalizedText(en: "Al Ummah Now", ar: "الأمة الآن"),
            handle: "alummahnow", isMain: true, role: .owner),
        StudioChannel(
            id: "fixture-channel-2", name: "Tafsir Circle", nameLocalized: LocalizedText(en: "Tafsir Circle", ar: "حلقة التفسير"),
            handle: "tafsir", role: .editor, capabilities: ["video.upload", "video.edit"]),
        StudioChannel(
            id: "fixture-channel-3", name: "Comments desk",
            nameLocalized: LocalizedText(en: "Comments desk", ar: "مكتب التعليقات"),
            role: .moderator, capabilities: ["comment.moderate"]),
    ]

    public func channels() async throws -> [StudioChannel] { Self.channels }

    public static let playlists = [
        StudioPlaylist(id: "fixture-playlist-1", title: "Tafsir series"),
        StudioPlaylist(id: "fixture-playlist-2", title: "Khutbahs", isPublic: false),
    ]

    public func playlists(channelID: String) async throws -> [StudioPlaylist] { Self.playlists }

    public func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
        UploadTicket(videoID: "fixture-video-\(UUID().uuidString.prefix(8))", tusSessionID: "fixture", chunkSize: 1 << 20)
    }

    public func resumeUpload(videoID: String, channelID: String) async throws -> UploadTicket {
        UploadTicket(videoID: videoID, tusSessionID: "fixture", chunkSize: 1 << 20)
    }

    public func completeUpload(videoID: String, fileSize: Int64, channelID: String) async throws {}
    public func tusEndpoint() async throws -> (url: URL, headers: [String: String]) {
        (URL(string: "https://fixtures.invalid/api/videos/tus")!, [:])
    }
    public func setLanguage(_ language: VideoLanguage, videoID: String, channelID: String) async throws {}
    public func addToPlaylists(_ playlistIDs: [String], videoID: String, orderKey: String, channelID: String) async throws {}
    public func schedule(videoID: String, at date: Date, timeZone: TimeZone, channelID: String) async throws {}

    public func content(channelID: String, query: ContentQuery, cursor: String?) async throws -> ContentPage {
        ContentPage(items: await store.page(query), cursor: nil)
    }

    public func contentCounts(channelID: String) async throws -> ContentCounts { await store.counts() }

    public func updateVideo(_ id: String, _ edit: VideoEdit, channelID: String) async throws {
        _ = await store.apply([id]) { video in
            if let title = edit.title {
                video.title = title
                video.titleLocalized = nil
            }
            if let description = edit.description { video.description = description }
            if let isPublic = edit.isPublic { video.isPublic = isPublic }
            if let category = edit.category { video.category = category }
            if let tags = edit.tags { video.tags = tags }
            if let language = edit.language { video.language = language }
        }
    }

    public func deleteVideos(_ ids: [String], channelID: String) async throws -> BulkResult { await store.delete(ids) }

    public func bulkUpdate(_ ids: [String], _ changes: BulkChanges, channelID: String) async throws -> BulkResult {
        await store.apply(ids) { video in
            if let isPublic = changes.isPublic { video.isPublic = isPublic }
            if let category = changes.category { video.category = category }
            video.tags = (video.tags + (changes.addTags ?? [])).filter { !(changes.removeTags ?? []).contains($0) }
        }
    }

    public func bulkSchedule(_ ids: [String], startAt: Date, intervalMinutes: Int, timeZone: TimeZone) async throws
        -> BulkResult
    {
        await store.apply(ids) { video in
            video.studioStatus = .scheduled
            video.scheduledPublishDate = startAt
        }
    }

    public func addToPlaylist(_ playlistID: String, videoIDs: [String], channelID: String) async throws {}

    public func deletedVideos(channelID: String, cursor: String?) async throws -> (items: [DeletedVideo], cursor: String?) {
        (await store.deleted, nil)
    }

    public func restoreVideos(_ ids: [String]) async throws -> BulkResult {
        await store.restore(ids, from: await original.videos)
    }

    public func purgeVideos(_ ids: [String]) async throws -> BulkResult { await store.purge(ids) }

    public func channelStats(channelID: String, period: DateInterval) async throws -> ChannelStats {
        let days = max(1, Int(period.duration / 86_400))
        let daily = (0..<min(days, 28)).map { day in
            DailyMetric(
                date: period.start.addingTimeInterval(Double(day) * 86_400).ISO8601Format().prefix(10).description,
                views: 40 + (day * 7) % 30, likes: 3, comments: 1, subscribers: day % 3, watchTime: Double(3600 + day * 120))
        }
        let videos = await store.videos.filter { $0.studioStatus == .published }
        return ChannelStats(
            totalViews: daily.reduce(0) { $0 + $1.views }, totalVideos: videos.count, totalSubscribers: 120, totalLikes: 90,
            totalComments: 25, engagementRate: 4.2,
            topVideos: videos.map {
                VideoStats(videoID: $0.id, title: $0.title, views: $0.views / 4, watchTime: 7200, averageViewDuration: 310)
            }, daily: daily)
    }

    public func videoStats(videoID: String, period: DateInterval) async throws -> VideoStats {
        let video = await store.videos.first { $0.id == videoID }
        return VideoStats(
            videoID: videoID, title: video?.title ?? "", views: (video?.views ?? 0) / 4, likes: 12, comments: 3, shares: 2,
            watchTime: 7200, averageViewDuration: 310, engagementRate: 5.1)
    }
}

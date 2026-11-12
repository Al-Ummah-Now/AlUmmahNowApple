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

    // Creator tier and account state
    func creatorAccess() async throws -> CreatorAccess
}

extension StudioServicing {
    /// Services that cannot tell allow everything; the server still refuses with a code.
    public func creatorAccess() async throws -> CreatorAccess { CreatorAccess() }
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

    struct CreatorEnvelope: Decodable {
        let data: CreatorAccess?
        let result: CreatorAccess?
    }

    public func creatorAccess() async throws -> CreatorAccess {
        let data = try await client.sendRaw(.get, "/api/me/creator")
        // The fields may sit at the top level or under `data`/`result`.
        if let envelope = try? StudioHTTPClient.decoder.decode(CreatorEnvelope.self, from: data),
            let access = envelope.data ?? envelope.result
        {
            return access
        }
        do {
            return try StudioHTTPClient.decoder.decode(CreatorAccess.self, from: data)
        } catch {
            throw CoreError.decoding
        }
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
            if let refusal = Refusal.parse(data) { throw CoreError.refused(refusal) }
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

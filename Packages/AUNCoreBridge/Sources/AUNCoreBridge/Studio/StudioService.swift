import Foundation

/// Creator Studio calls to api-videos, the same routes the web Studio uses. Every call acts as the active account.
public protocol StudioServicing: Sendable {
    /// Channels the person owns or helps run, owned first (`GET /api/channels/access`).
    func channels() async throws -> [StudioChannel]
}

/// api-videos over URLSession with the active account's bearer token.
public struct NativeStudioService: StudioServicing {
    let client: StudioHTTPClient

    public init(baseURL: URL, accounts: any AccountServicing, session: URLSession = .shared) {
        client = StudioHTTPClient(baseURL: baseURL, accounts: accounts, session: session)
    }

    struct DataEnvelope<T: Decodable>: Decodable { let data: T }

    public func channels() async throws -> [StudioChannel] {
        try await client.send(.get, "/api/channels/access", as: DataEnvelope<[StudioChannel]>.self).data
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
            try container.encode(date.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
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

/// Bilingual channels and videos for UI tests, snapshots and previews.
public struct FixtureStudioService: StudioServicing {
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
}

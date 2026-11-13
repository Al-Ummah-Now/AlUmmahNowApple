import Foundation

/// admin-api's review routes over the private session, with the signed-in reviewer's bearer token. URLs and bodies
/// are never logged (a frame request names the review; a stream URL carries a signature).
public struct NativeReviewService: ReviewServicing, PushRegistering {
    let adminAPI: URL
    let videosAPI: URL
    let accounts: any AccountServicing
    let session: URLSession

    public init(
        adminAPI: URL, videosAPI: URL, accounts: any AccountServicing, session: URLSession = PrivateMediaSession.shared
    ) {
        self.adminAPI = adminAPI
        self.videosAPI = videosAPI
        self.accounts = accounts
        self.session = session
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not ISO 8601"))
        }
        return decoder
    }()

    struct Envelope<T: Decodable>: Decodable { let result: T }

    struct ErrorBody: Decodable {
        let code: String?
        let error: String?
        let decision: String?
        let decidedByName: String?
        let decidedAt: Date?
        let assignedToName: String?
    }

    // MARK: Transport

    func send(
        _ method: String, _ base: URL, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil
    ) async throws -> Data {
        guard var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw CoreError.notFound
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url, url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1"
        else { throw CoreError.forbidden }
        var request = PrivateMediaSession.request(url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let token = try await accounts.accessToken() else { throw CoreError.signInRequired }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) {
            throw CoreError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.failure(status: status, data: data) }
        return data
    }

    static func failure(status: Int, data: Data) -> any Error {
        let body = try? decoder.decode(ErrorBody.self, from: data)
        switch (status, body?.code) {
        case (401, _): return CoreError.signInRequired
        case (_, "step_up_required"): return ReviewError.stepUpRequired
        case (_, "reviewer_only"), (_, "staff_only"): return ReviewError.notStaff
        case (_, "undo_expired"): return ReviewError.undoExpired
        case (_, "claimed"): return ReviewError.claimedByOther(name: body?.assignedToName)
        case (409, _):
            return ReviewError.alreadyDecided(decision: body?.decision, byName: body?.decidedByName, at: body?.decidedAt)
        case (403, _): return CoreError.forbidden
        case (404, _): return CoreError.notFound
        default: return CoreError.http(status: status)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try Self.decoder.decode(Envelope<T>.self, from: data).result } catch { throw CoreError.decoding }
    }

    // MARK: ReviewServicing

    struct MeResult: Decodable {
        let userId: String?
        let displayName: String?
        let roles: [String]?
        let permissions: [String]?
    }

    public func profile() async throws -> StaffProfile {
        do {
            let me = try decode(MeResult.self, try await send("GET", adminAPI, "/api/me"))
            guard let id = me.userId else { throw CoreError.decoding }
            let profile = StaffProfile(
                userID: id, displayName: me.displayName, roles: me.roles ?? [], permissions: me.permissions ?? [])
            guard profile.isReviewer || profile.permissions.contains(where: { $0.hasPrefix("review:") }) else {
                throw ReviewError.notStaff
            }
            return profile
        } catch CoreError.notFound {
            // A server without `GET /api/me` yet: the queue itself answers whether this account is a reviewer.
            _ = try await queue(.actionNeeded, query: nil, cursor: nil)
            let account = try await accounts.activeAccount()
            return StaffProfile(userID: account?.id ?? "", displayName: account?.displayName, roles: ["content_reviewer"])
        } catch CoreError.forbidden {
            throw ReviewError.notStaff
        }
    }

    struct QueueResult: Decodable {
        let items: [ReviewItem]
        let nextCursor: String?
    }

    public func queue(_ tab: ReviewTab, query: String?, cursor: String?) async throws -> ReviewPage {
        var items = [URLQueryItem(name: "tab", value: tab.rawValue), URLQueryItem(name: "limit", value: "50")]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        do {
            let page = try decode(QueueResult.self, try await send("GET", adminAPI, "/api/review/queue", query: items))
            return ReviewPage(items: page.items, nextCursor: page.nextCursor)
        } catch CoreError.forbidden {
            throw ReviewError.notStaff
        }
    }

    struct DetailResult: Decodable {
        struct Manifest: Decodable {
            struct Frame: Decodable {
                let key: String
                let atMs: Int
            }
            let frames: [Frame]
        }
        let review: ReviewItem
        let findings: [ReviewFinding]?
        let history: [ReviewHistoryEntry]?
        let subject: ReviewSubject?
        let manifest: Manifest?
        let stream: ReviewStream?
    }

    public func detail(_ id: String) async throws -> ReviewDetail {
        let result = try decode(DetailResult.self, try await send("GET", adminAPI, "/api/review/\(id)"))
        let findings = result.findings ?? []
        let manifest = (result.manifest?.frames ?? []).map { ReviewFrame(key: $0.key, atMs: $0.atMs, flagged: false) }
        var item = result.review
        if item.title == nil { item.title = result.subject?.title }
        return ReviewDetail(
            item: item, findings: findings, history: (result.history ?? []).filter { $0.id != id },
            subject: result.subject, frames: ReviewDetail.frames(findings: findings, manifest: manifest),
            stream: result.stream)
    }

    public func claim(_ id: String) async throws {
        _ = try await send("POST", adminAPI, "/api/review/\(id)/claim", body: [:])
    }

    public func reveal(_ id: String, target: String) async throws {
        _ = try await send("POST", adminAPI, "/api/review/\(id)/reveal", body: ["target": target])
    }

    struct DecisionBody: Decodable { let review: ReviewItem }

    public func decide(
        _ id: String, _ decision: ReviewDecision, reason: ReviewReason?, note: String?, version: Int?
    ) async throws -> DecisionResult {
        var body: [String: Any] = ["decision": decision.rawValue]
        if let reason { body["reasonCode"] = reason.rawValue }
        if let note, !note.isEmpty { body["note"] = String(note.prefix(1000)) }
        if let version { body["version"] = version }
        let result = try decode(DecisionBody.self, try await send("POST", adminAPI, "/api/review/\(id)/decision", body: body))
        return DecisionResult(item: result.review)
    }

    public func media(_ id: String, key: String) async throws -> Data {
        try await send("GET", adminAPI, "/api/review/\(id)/media", query: [URLQueryItem(name: "key", value: key)])
    }

    public func recordCapture(_ event: CaptureEvent, reviewID: String?, installID: String) async throws {
        var body: [String: Any] = ["event": event.rawValue, "installId": installID]
        if let reviewID { body["reviewId"] = reviewID }
        _ = try await send("POST", adminAPI, "/api/review/audit/capture", body: body)
    }

    // MARK: PushRegistering

    public func register(installID: String, token: String, platform: String, locale: String, appVersion: String) async throws {
        let body: [String: Any] = [
            "app": "admin", "platform": platform, "provider": "apns", "token": token, "locale": locale,
            "appVersion": String(appVersion.prefix(32)),
        ]
        _ = try await send("PUT", videosAPI, "/api/v1/devices/\(installID)", body: body)
    }

    public func unregister(installID: String) async throws {
        _ = try await send("DELETE", videosAPI, "/api/v1/devices/\(installID)")
    }
}

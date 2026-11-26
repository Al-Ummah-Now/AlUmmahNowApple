import Foundation

/// A server's answer, as it came: the caller decides what each status means.
public struct DeletionAnswer: Sendable {
    public let status: Int
    public let body: Data
    public let retryAfter: String?

    public init(status: Int, body: Data = Data(), retryAfter: String? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }

    public init(_ status: Int, json: String, retryAfter: String? = nil) {
        self.init(status: status, body: Data(json.utf8), retryAfter: retryAfter)
    }
}

extension DeletionAnswer {
    private struct Body: Decodable {
        let error: String?
        let deleted: Bool?
        let receipt: String?
        let expiresAt: Double?
    }

    private var decoded: Body? { try? JSONDecoder().decode(Body.self, from: body) }

    var deleted: Bool? { decoded?.deleted }

    /// The receipt and until when Auth takes it (milliseconds since 1970).
    var receipt: (value: String, expires: Date?)? {
        guard status == 200, let body = decoded, let receipt = body.receipt, !receipt.isEmpty else { return nil }
        return (receipt, body.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    /// Auth's own 404 (`{"error":"not_found"}`), about the account the token is for; any other 404 is a missing route.
    var saysNoAccount: Bool { status == 404 && decoded?.error == "not_found" }

    var needsSignIn: Bool { status == 401 && decoded?.error == "insufficient_user_authentication" }

    /// `deleted: true`, or no account under the id whose content was erased just now: gone already.
    var saysDeleted: Bool {
        (200..<300).contains(status) ? decoded?.deleted == true : saysNoAccount
    }

    /// Seconds of `Retry-After` (a number or a date), never less than it says; five minutes when it says nothing.
    func retryAfterSeconds(now: Date) -> TimeInterval {
        let value = retryAfter?.trimmingCharacters(in: .whitespaces) ?? ""
        let seconds: TimeInterval?
        if !value.isEmpty, value.allSatisfy({ ("0"..."9").contains($0) }) {
            seconds = TimeInterval(value)
        } else {
            seconds = HTTPDate.parse(value).map { $0.timeIntervalSince(now) }
        }
        guard let seconds, seconds > 0 else { return 300 }
        // Ten years: only so that a number too large for a clock stays one.
        return min(seconds, 315_360_000)
    }
}

/// The calls of an account deletion. Each throws when no answer came.
public protocol DeletionServicing: Sendable {
    /// `DELETE /api/privacy/data`: one bounded pass.
    func erase(accountID: String, token: String, resumeToken: String?) async throws -> DeletionAnswer
    /// `DELETE /account` on Auth.
    func deleteAccount(token: String) async throws -> DeletionAnswer
    /// `POST /account/deletion-receipt` on Auth: what `accountStatus` takes.
    func deletionReceipt(token: String) async throws -> DeletionAnswer
    /// `GET /account/status` on Auth: whether the receipt's account is deleted.
    func accountStatus(receipt: String) async throws -> DeletionAnswer
    /// The server's clock, or nil when it did not say: a device's clock must not decide what is wiped.
    func serverNow() async -> Date?
}

/// `DeletionServicing` over HTTPS. Every request has a limited time, so nothing waits for an answer that never comes.
public struct NativeDeletionService: DeletionServicing {
    private let api: URL
    private let auth: URL
    private let proofs: (any NativeProofProviding)?
    private let session: URLSession

    public init(
        apiBaseURL: URL, authIssuer: URL, proofs: (any NativeProofProviding)? = nil,
        session: URLSession = NativeDeletionService.limited()
    ) {
        api = apiBaseURL
        auth = authIssuer
        self.proofs = proofs
        self.session = session
    }

    /// No cache, no cookies, and a minute for a whole request.
    public static func limited(_ configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.timeoutIntervalForRequest = callLimit
        configuration.timeoutIntervalForResource = callLimit
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    static let callLimit: TimeInterval = 60
    private static let statusLimit: TimeInterval = 15

    private struct EraseRequest: Encodable {
        let confirm = "DELETE"
        let resumeToken: String?
    }

    public func erase(accountID: String, token: String, resumeToken: String?) async throws -> DeletionAnswer {
        var request = request("DELETE", api.appending(path: "/api/privacy/data"), token)
        request.httpBody = try JSONEncoder().encode(EraseRequest(resumeToken: resumeToken))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let first = try await send(request, proof: await proofs?.proof(account: accountID, fresh: false))
        guard first.status == 403, StudioHTTPClient.needsProof(first.body),
            let fresh = await proofs?.proof(account: accountID, fresh: true)
        else { return first }
        return try await send(request, proof: fresh)
    }

    public func deleteAccount(token: String) async throws -> DeletionAnswer {
        try await send(request("DELETE", auth.appending(path: "/account"), token))
    }

    public func deletionReceipt(token: String) async throws -> DeletionAnswer {
        try await send(request("POST", auth.appending(path: "/account/deletion-receipt"), token))
    }

    public func accountStatus(receipt: String) async throws -> DeletionAnswer {
        var request = request("GET", auth.appending(path: "/account/status"), receipt, scheme: "Deletion-Receipt")
        request.timeoutInterval = Self.statusLimit
        return try await send(request)
    }

    public func serverNow() async -> Date? {
        var request = URLRequest(url: auth.appending(path: "/.well-known/oauth-authorization-server"))
        request.timeoutInterval = Self.statusLimit
        request.setAUNClient()
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date").flatMap(HTTPDate.parse)
    }

    private func request(_ method: String, _ url: URL, _ token: String, scheme: String = "Bearer") -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.callLimit)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(scheme) \(token)", forHTTPHeaderField: "Authorization")
        request.setAUNClient()
        return request
    }

    private func send(_ base: URLRequest, proof: String? = nil) async throws -> DeletionAnswer {
        var request = base
        if let proof { request.setValue(proof, forHTTPHeaderField: StudioHTTPClient.proofHeader) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return DeletionAnswer(
            status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    }
}

/// HTTP dates (RFC 9110, IMF-fixdate).
enum HTTPDate {
    static func parse(_ value: String) -> Date? {
        // swiftlint:disable display_format
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        // swiftlint:enable display_format
        return format.date(from: value.trimmingCharacters(in: .whitespaces))
    }
}

/// What an OpenAuth access token says. Its signature is checked by the server that gets it; this only reads.
public enum DeletionToken {
    private static let maxFutureSkew: Double = 60

    /// The account: `properties.id`, or nil. Never `sub`, which is a hashed subject (`user:<hex>`).
    public static func accountID(of token: String) -> String? {
        guard let properties = payload(token)?["properties"] as? [String: Any],
            let id = properties["id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    /// Whether the person signed in within `maxAge` seconds of `now` (`auth_time`).
    public static func isRecent(_ token: String, now: Date, maxAge: Int) -> Bool {
        guard let authTime = (payload(token)?["auth_time"] as? NSNumber)?.doubleValue else { return false }
        let age = now.timeIntervalSince1970 - authTime
        return age >= -maxFutureSkew && age <= Double(maxAge)
    }

    /// An unsigned token, for fixtures and tests. No server accepts it.
    public static func fixture(accountID: String, authTime: Date) -> String {
        func part(_ object: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data()
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let payload: [String: Any] = [
            "mode": "access", "sub": "user:0123456789abcdef", "properties": ["id": accountID],
            "auth_time": Int(authTime.timeIntervalSince1970),
        ]
        return "\(part(["alg": "none"])).\(part(payload)).fixture"
    }

    private static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

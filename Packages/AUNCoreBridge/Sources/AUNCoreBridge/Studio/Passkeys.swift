import Foundation

// Native passkeys (AUTH-PASSKEYS, "Native apps"): the app asks the auth server for WebAuthn options, runs the
// platform passkey sheet itself, and trades the signed assertion for an OAuth code. The code is exchanged at the
// usual token endpoint with the PKCE verifier of a normal sign-in, so the session code path stays one.

/// Base64url without padding (RFC 4648 §5), the encoding WebAuthn JSON uses for binary fields.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts padded or unpadded input, and plain base64 too.
    public static func decode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

/// The PKCE values of a pending sign-in, read from its authorize URL, so a passkey sign-in can reuse them.
public struct PKCESignIn: Hashable, Sendable {
    public var issuer: URL
    public var clientID: String
    public var codeChallenge: String
    public var state: String
    public var redirectURI: String

    /// The redirect the browser flow would have returned, for `AccountServicing.completeSignIn(redirect:)`.
    public func redirect(code: String) -> URL? {
        guard var parts = URLComponents(string: redirectURI) else { return nil }
        parts.queryItems = (parts.queryItems ?? []) + [
            URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state),
        ]
        return parts.url
    }
}

extension SignInRequest {
    /// The PKCE values in `url`, when it is an S256 authorize request with a client, a state and a redirect.
    public var pkce: PKCESignIn? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary(
            (parts.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
        guard let client = query["client_id"], let challenge = query["code_challenge"], let state = query["state"],
            let redirect = query["redirect_uri"], query["code_challenge_method"] == "S256"
        else { return nil }
        var issuer = parts
        issuer.query = nil
        issuer.fragment = nil
        if issuer.path.hasSuffix("/authorize") { issuer.path = String(issuer.path.dropLast("/authorize".count)) }
        guard let issuerURL = issuer.url else { return nil }
        return PKCESignIn(
            issuer: issuerURL, clientID: client, codeChallenge: challenge, state: state, redirectURI: redirect)
    }
}

/// `PublicKeyCredentialRequestOptionsJSON` plus the server's challenge id.
public struct PasskeyRequestOptions: Hashable, Sendable {
    public var challengeID: String
    public var challenge: Data
    public var rpID: String
    /// Empty: any discoverable passkey for the relying party.
    public var allowCredentialIDs: [Data]
    public var userVerification: String?
    public var timeout: TimeInterval?

    public init(
        challengeID: String, challenge: Data, rpID: String, allowCredentialIDs: [Data] = [],
        userVerification: String? = nil, timeout: TimeInterval? = nil
    ) {
        self.challengeID = challengeID
        self.challenge = challenge
        self.rpID = rpID
        self.allowCredentialIDs = allowCredentialIDs
        self.userVerification = userVerification
        self.timeout = timeout
    }
}

/// `PublicKeyCredentialCreationOptionsJSON` plus the server's challenge id.
public struct PasskeyCreationOptions: Hashable, Sendable {
    public var challengeID: String
    public var challenge: Data
    public var rpID: String
    public var rpName: String?
    public var userID: Data
    public var userName: String
    public var userDisplayName: String?
    public var excludeCredentialIDs: [Data]
    public var userVerification: String?
    public var attestation: String?

    public init(
        challengeID: String, challenge: Data, rpID: String, rpName: String? = nil, userID: Data, userName: String,
        userDisplayName: String? = nil, excludeCredentialIDs: [Data] = [], userVerification: String? = nil,
        attestation: String? = nil
    ) {
        self.challengeID = challengeID
        self.challenge = challenge
        self.rpID = rpID
        self.rpName = rpName
        self.userID = userID
        self.userName = userName
        self.userDisplayName = userDisplayName
        self.excludeCredentialIDs = excludeCredentialIDs
        self.userVerification = userVerification
        self.attestation = attestation
    }
}

/// Where the passkey came from: this device (or its synced password manager), or a phone or security key.
public enum PasskeyAttachment: String, Hashable, Sendable {
    case platform
    case crossPlatform = "cross-platform"
}

/// A signed assertion from the platform sheet.
public struct PasskeyAssertion: Hashable, Sendable {
    public var credentialID: Data
    public var clientDataJSON: Data
    public var authenticatorData: Data
    public var signature: Data
    public var userHandle: Data?
    public var attachment: PasskeyAttachment?

    public init(
        credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data? = nil,
        attachment: PasskeyAttachment? = nil
    ) {
        self.credentialID = credentialID
        self.clientDataJSON = clientDataJSON
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.userHandle = userHandle
        self.attachment = attachment
    }

    /// `AuthenticationResponseJSON`.
    public var json: [String: Any] {
        var response: [String: Any] = [
            "clientDataJSON": Base64URL.encode(clientDataJSON),
            "authenticatorData": Base64URL.encode(authenticatorData),
            "signature": Base64URL.encode(signature),
        ]
        if let userHandle { response["userHandle"] = Base64URL.encode(userHandle) }
        var credential: [String: Any] = [
            "id": Base64URL.encode(credentialID), "rawId": Base64URL.encode(credentialID), "type": "public-key",
            "response": response, "clientExtensionResults": [String: Any](),
        ]
        if let attachment { credential["authenticatorAttachment"] = attachment.rawValue }
        return credential
    }
}

/// A new passkey from the platform sheet.
public struct PasskeyRegistration: Hashable, Sendable {
    public var credentialID: Data
    public var clientDataJSON: Data
    public var attestationObject: Data
    public var attachment: PasskeyAttachment?
    public var transports: [String]

    public init(
        credentialID: Data, clientDataJSON: Data, attestationObject: Data, attachment: PasskeyAttachment? = nil,
        transports: [String] = []
    ) {
        self.credentialID = credentialID
        self.clientDataJSON = clientDataJSON
        self.attestationObject = attestationObject
        self.attachment = attachment
        self.transports = transports
    }

    /// `RegistrationResponseJSON`.
    public var json: [String: Any] {
        var credential: [String: Any] = [
            "id": Base64URL.encode(credentialID), "rawId": Base64URL.encode(credentialID), "type": "public-key",
            "response": [
                "clientDataJSON": Base64URL.encode(clientDataJSON),
                "attestationObject": Base64URL.encode(attestationObject), "transports": transports,
            ] as [String: Any],
            "clientExtensionResults": [String: Any](),
        ]
        if let attachment { credential["authenticatorAttachment"] = attachment.rawValue }
        return credential
    }
}

/// A passkey saved on the account.
public struct PasskeyRecord: Hashable, Sendable {
    public var id: String
    public var name: String?
    public var createdAt: String?

    public init(id: String, name: String? = nil, createdAt: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// Why a passkey ceremony or call failed. `cancelled` is never shown.
public enum PasskeyError: Error, Equatable, Sendable {
    /// The person closed the sheet.
    case cancelled
    /// The server knows no account for this passkey (it was removed), or the device has none to offer.
    case noCredential
    /// Adding a passkey needs a sign-in from the last 15 minutes.
    case stepUpRequired
    /// Too many tries; `retryAfter` seconds from the `Retry-After` header when the server sent one.
    case rateLimited(retryAfter: Int?)
    /// This device already has a passkey for the account.
    case alreadyRegistered
    /// The account has the most passkeys it may have.
    case limit
    /// The app is not associated with the relying party's domain (`webcredentials:` entitlement and the server's
    /// apple-app-site-association file), so the platform refuses to run the ceremony.
    case notAssociated
    case offline
    /// The token was refused: the account has to sign in again.
    case signInRequired
    /// Anything else, with the server's `error` code when there was one.
    case failed(String?)

    /// Maps an error answer of the native passkey endpoints.
    public static func from(status: Int, code: String?, retryAfter: String?) -> PasskeyError {
        switch code {
        case "step_up_required", "stale_sign_in": return .stepUpRequired
        case "unknown_credential", "credential_not_found", "passkey_not_found", "no_passkey": return .noCredential
        case "exists", "credential_exists", "already_registered": return .alreadyRegistered
        case "limit", "passkey_limit": return .limit
        default: break
        }
        switch status {
        case 429: return .rateLimited(retryAfter: retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        case 401: return .signInRequired
        default: return .failed(code)
        }
    }
}

/// The auth server's native passkey endpoints. `NativePasskeyService` implements it over HTTPS.
public protocol PasskeyServicing: Sendable {
    /// `POST /native/passkey/options`: a challenge for the sign-in bound to `codeChallenge`.
    func signInOptions(issuer: URL, clientID: String, codeChallenge: String) async throws -> PasskeyRequestOptions
    /// `POST /native/passkey/verify`: the OAuth code for the signed assertion.
    func verifySignIn(issuer: URL, challengeID: String, clientID: String, assertion: PasskeyAssertion) async throws
        -> String
    /// `POST /native/passkey/register/options` (Bearer). `PasskeyError.stepUpRequired` when the sign-in is too old.
    func registrationOptions(issuer: URL, accessToken: String) async throws -> PasskeyCreationOptions
    /// `POST /native/passkey/register/verify` (Bearer).
    func verifyRegistration(
        issuer: URL, accessToken: String, challengeID: String, registration: PasskeyRegistration, name: String?
    ) async throws -> PasskeyRecord
}

/// `PasskeyServicing` over URLSession.
public struct NativePasskeyService: PasskeyServicing {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func signInOptions(issuer: URL, clientID: String, codeChallenge: String) async throws
        -> PasskeyRequestOptions
    {
        let body: [String: Any] = [
            "client_id": clientID, "code_challenge": codeChallenge, "code_challenge_method": "S256",
        ]
        let json = try await post(issuer, "native/passkey/options", body: body, token: nil)
        return try Self.requestOptions(json)
    }

    public func verifySignIn(issuer: URL, challengeID: String, clientID: String, assertion: PasskeyAssertion)
        async throws -> String
    {
        let body: [String: Any] = ["challenge_id": challengeID, "client_id": clientID, "credential": assertion.json]
        let json = try await post(issuer, "native/passkey/verify", body: body, token: nil)
        guard let code = json["code"] as? String, !code.isEmpty else { throw PasskeyError.failed("no_code") }
        return code
    }

    public func registrationOptions(issuer: URL, accessToken: String) async throws -> PasskeyCreationOptions {
        let json = try await post(issuer, "native/passkey/register/options", body: [:], token: accessToken)
        return try Self.creationOptions(json)
    }

    public func verifyRegistration(
        issuer: URL, accessToken: String, challengeID: String, registration: PasskeyRegistration, name: String?
    ) async throws -> PasskeyRecord {
        var body: [String: Any] = ["challenge_id": challengeID, "credential": registration.json]
        if let name { body["name"] = name }
        let json = try await post(issuer, "native/passkey/register/verify", body: body, token: accessToken)
        guard let id = json["id"] as? String else { throw PasskeyError.failed("no_id") }
        return PasskeyRecord(id: id, name: json["name"] as? String, createdAt: json["created_at"] as? String)
    }

    private func post(_ issuer: URL, _ path: String, body: [String: Any], token: String?) async throws
        -> [String: Any]
    {
        var request = URLRequest(url: issuer.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            throw PasskeyError.offline
        } catch {
            throw PasskeyError.failed(nil)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            throw PasskeyError.from(status: status, code: json?["error"] as? String, retryAfter: retryAfter)
        }
        guard let json else { throw PasskeyError.failed("decoding") }
        return json
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
        .dataNotAllowed, .internationalRoamingOff,
    ]

    static func requestOptions(_ json: [String: Any]) throws -> PasskeyRequestOptions {
        guard let challengeID = json["challenge_id"] as? String, let key = json["publicKey"] as? [String: Any],
            let challenge = (key["challenge"] as? String).flatMap(Base64URL.decode),
            let rpID = key["rpId"] as? String
        else { throw PasskeyError.failed("decoding") }
        let allowed = (key["allowCredentials"] as? [[String: Any]] ?? []).compactMap {
            ($0["id"] as? String).flatMap(Base64URL.decode)
        }
        return PasskeyRequestOptions(
            challengeID: challengeID, challenge: challenge, rpID: rpID, allowCredentialIDs: allowed,
            userVerification: key["userVerification"] as? String,
            timeout: (key["timeout"] as? Double).map { $0 / 1000 })
    }

    static func creationOptions(_ json: [String: Any]) throws -> PasskeyCreationOptions {
        guard let challengeID = json["challenge_id"] as? String, let key = json["publicKey"] as? [String: Any],
            let challenge = (key["challenge"] as? String).flatMap(Base64URL.decode),
            let rp = key["rp"] as? [String: Any], let user = key["user"] as? [String: Any],
            let userID = (user["id"] as? String).flatMap(Base64URL.decode), let userName = user["name"] as? String
        else { throw PasskeyError.failed("decoding") }
        guard let rpID = rp["id"] as? String else { throw PasskeyError.failed("decoding") }
        let excluded = (key["excludeCredentials"] as? [[String: Any]] ?? []).compactMap {
            ($0["id"] as? String).flatMap(Base64URL.decode)
        }
        let selection = key["authenticatorSelection"] as? [String: Any]
        return PasskeyCreationOptions(
            challengeID: challengeID, challenge: challenge, rpID: rpID, rpName: rp["name"] as? String,
            userID: userID, userName: userName, userDisplayName: user["displayName"] as? String,
            excludeCredentialIDs: excluded, userVerification: selection?["userVerification"] as? String,
            attestation: key["attestation"] as? String)
    }
}

/// Passkey endpoints in memory, for UI tests and previews. `stepUp` asks for a fresh sign-in once, then succeeds.
public actor FixturePasskeyService: PasskeyServicing {
    public enum Outcome: String, Sendable {
        case success, noCredential, stepUp, rateLimited
    }

    public let outcome: Outcome
    private var stepUpsLeft = 1

    public init(outcome: Outcome = .success) { self.outcome = outcome }

    public func signInOptions(issuer: URL, clientID: String, codeChallenge: String) async throws
        -> PasskeyRequestOptions
    {
        if outcome == .rateLimited { throw PasskeyError.rateLimited(retryAfter: 30) }
        return PasskeyRequestOptions(
            challengeID: "fixture-challenge", challenge: Data("fixture".utf8), rpID: "qa.alummahnow.net")
    }

    public func verifySignIn(issuer: URL, challengeID: String, clientID: String, assertion: PasskeyAssertion)
        async throws -> String
    {
        if outcome == .noCredential { throw PasskeyError.noCredential }
        return "fixture"
    }

    public func registrationOptions(issuer: URL, accessToken: String) async throws -> PasskeyCreationOptions {
        if outcome == .stepUp, stepUpsLeft > 0 {
            stepUpsLeft -= 1
            throw PasskeyError.stepUpRequired
        }
        return PasskeyCreationOptions(
            challengeID: "fixture-challenge", challenge: Data("fixture".utf8), rpID: "qa.alummahnow.net",
            userID: Data("fixture-creator".utf8), userName: "creator@example.org")
    }

    public func verifyRegistration(
        issuer: URL, accessToken: String, challengeID: String, registration: PasskeyRegistration, name: String?
    ) async throws -> PasskeyRecord {
        PasskeyRecord(id: "fixture-passkey", name: name ?? "iCloud Keychain")
    }
}

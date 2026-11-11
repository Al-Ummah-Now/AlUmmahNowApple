import AUNCoreBridge
import AunCore
import Foundation

/// `AccountServicing` on aun-auth: PKCE sign-in, several accounts per device, tokens in the Keychain.
public final class CoreAccountService: AccountServicing, @unchecked Sendable {
    public static let callbackScheme = "alummahnow-studio"
    public static let redirectURI = "\(callbackScheme)://auth/callback"
    static let scopes = ["openid", "profile", "email", "offline_access"]

    let manager: AuthManager

    public init(issuer: URL, clientID: String, storage: SecureStorage) throws {
        let issuer = issuer.absoluteString.hasSuffix("/") ? String(issuer.absoluteString.dropLast()) : issuer.absoluteString
        manager = try AuthManager(
            config: AuthConfig(
                issuer: issuer, clientId: clientID, redirectUri: Self.redirectURI, scopes: Self.scopes,
                authorizationEndpoint: "\(issuer)/authorize", tokenEndpoint: "\(issuer)/token",
                deviceAuthorizationEndpoint: nil),
            storage: storage)
    }

    /// The service for an app build: its issuer and client from Info.plist, its Keychain service from the bundle id.
    public static func live(environment: AppEnvironment, bundleID: String) throws -> CoreAccountService {
        guard let client = environment.oauthClientID else { throw CoreError.signInRequired }
        return try CoreAccountService(
            issuer: environment.authIssuer, clientID: client, storage: KeychainStorage(service: "\(bundleID).accounts"))
    }

    public func accounts() async throws -> [StudioAccount] {
        try map { try manager.accounts().map(StudioAccount.init) }
    }

    public func activeAccount() async throws -> StudioAccount? {
        try map { try manager.activeAccount().map(StudioAccount.init) }
    }

    public func beginSignIn(_ prompt: SignInPrompt) async throws -> SignInRequest {
        // The web session is ephemeral (no shared cookies), so every sign-in shows the form and adding an account
        // needs no `prompt=login`.
        let request = try map { try manager.beginLogin() }
        guard let url = URL(string: request.url) else { throw CoreError.signInRequired }
        return SignInRequest(url: url, callbackScheme: Self.callbackScheme)
    }

    public func completeSignIn(redirect: URL) async throws -> StudioAccount {
        let account = try await mapAsync { try await manager.completeLogin(redirectUrl: redirect.absoluteString) }
        return StudioAccount(account)
    }

    public func switchAccount(to id: String) async throws -> StudioAccount {
        try map { StudioAccount(try manager.switchAccount(userId: id)) }
    }

    public func signOut(_ id: String) async throws {
        try map { try manager.signOut(userId: id) }
    }

    public func setActiveChannel(_ channelID: String?) async throws {
        try map { try manager.setActiveChannel(channelId: channelID) }
    }

    public func accessToken() async throws -> String? {
        try await mapAsync { try await manager.accessToken() }
    }

    private func map<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as AunError { throw CoreError(error) }
    }

    private func mapAsync<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let error as AunError { throw CoreError(error) }
    }
}

extension StudioAccount {
    init(_ info: AccountInfo) {
        self.init(
            id: info.userId, email: info.email, displayName: info.displayName,
            avatarURL: info.avatarUrl.flatMap(URL.init(string:)), activeChannelID: info.activeChannelId,
            needsReauth: info.needsReauth)
    }
}

extension CoreError {
    /// Maps aun-core errors onto the bridge's error type, so features never import AunCore.
    init(_ error: AunError) {
        switch error {
        case .Unauthorized: self = .signInRequired
        case .NotFound: self = .notFound
        case .Cancelled: self = .cancelled
        case .Http(let status, _, _): self = .http(status: Int(status))
        case .Forbidden: self = .forbidden
        case .Conflict: self = .http(status: 409)
        case .RateLimited: self = .http(status: 429)
        case .Offline, .Network: self = .offline
        default: self = .upload(error.localizedDescription)
        }
    }
}

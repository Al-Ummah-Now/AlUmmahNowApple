import Foundation

/// A signed-in account on this device. It never carries tokens.
public struct StudioAccount: Identifiable, Hashable, Sendable {
    public var id: String
    public var email: String?
    public var displayName: String?
    public var avatarURL: URL?
    public var activeChannelID: String?
    /// The refresh token was rejected, so the person has to sign in again.
    public var needsReauth: Bool

    public init(
        id: String, email: String? = nil, displayName: String? = nil, avatarURL: URL? = nil,
        activeChannelID: String? = nil, needsReauth: Bool = false
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.activeChannelID = activeChannelID
        self.needsReauth = needsReauth
    }

    /// The name to show: display name, then email, then the id.
    public var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let email, !email.isEmpty { return email }
        return id
    }
}

/// How the sign-in page is opened.
public enum SignInPrompt: Sendable, Hashable {
    /// The normal sign-in.
    case standard
    /// Always shows the form, to add a second account.
    case addAccount
    /// A fresh sign-in of the same person (`prompt=login&max_age=<seconds>`) before a high-risk action; the server
    /// checks `auth_time`.
    case stepUp(maxAge: Int)
}

/// A pending browser sign-in: open `url`, then hand the redirect back to `completeSignIn`.
public struct SignInRequest: Hashable, Sendable {
    public var url: URL
    public var callbackScheme: String

    public init(url: URL, callbackScheme: String) {
        self.url = url
        self.callbackScheme = callbackScheme
    }
}

/// Sign-in, accounts and tokens (OAuth 2 with PKCE through the auth server). `aun-auth` implements it.
public protocol AccountServicing: Sendable {
    func accounts() async throws -> [StudioAccount]
    func activeAccount() async throws -> StudioAccount?
    func beginSignIn(_ prompt: SignInPrompt) async throws -> SignInRequest
    /// Exchanges the code in `redirect` and makes the new account active.
    func completeSignIn(redirect: URL) async throws -> StudioAccount
    func switchAccount(to id: String) async throws -> StudioAccount
    /// Removes the account from this device and revokes its refresh token on the server. Never blocked by the network.
    func signOut(_ id: String) async throws
    func setActiveChannel(_ channelID: String?) async throws
    /// A valid access token for the active account, refreshed when it is close to expiry.
    func accessToken() async throws -> String?
}

/// Accounts held in memory, for UI tests, snapshots and previews.
public actor FixtureAccountService: AccountServicing {
    public static let callbackScheme = "alummahnow-studio"
    private var stored: [StudioAccount]
    private var active: String?
    private var next = 1
    private var lastPrompt: SignInPrompt = .standard

    public init(signedIn: [StudioAccount] = []) {
        stored = signedIn
        active = signedIn.first?.id
    }

    public static let creator = StudioAccount(
        id: "fixture-creator", email: "creator@example.org", displayName: "Fixture Creator")

    public func accounts() -> [StudioAccount] { stored }
    public func activeAccount() -> StudioAccount? { stored.first { $0.id == active } }

    public func beginSignIn(_ prompt: SignInPrompt) -> SignInRequest {
        lastPrompt = prompt
        return SignInRequest(url: URL(string: "https://auth.fixtures.invalid/authorize")!, callbackScheme: Self.callbackScheme)
    }

    public func completeSignIn(redirect: URL) throws -> StudioAccount {
        // A step-up signs the same person in again.
        if case .stepUp = lastPrompt, let current = activeAccount() { return current }
        let account =
            stored.isEmpty
            ? Self.creator
            : StudioAccount(id: "fixture-account-\(next)", email: "account\(next)@example.org")
        next += 1
        if !stored.contains(where: { $0.id == account.id }) { stored.append(account) }
        active = account.id
        return account
    }

    public func switchAccount(to id: String) throws -> StudioAccount {
        guard let account = stored.first(where: { $0.id == id }) else { throw CoreError.notFound }
        active = id
        return account
    }

    public func signOut(_ id: String) {
        stored.removeAll { $0.id == id }
        if active == id { active = stored.first?.id }
    }

    public func setActiveChannel(_ channelID: String?) {
        guard let index = stored.firstIndex(where: { $0.id == active }) else { return }
        stored[index].activeChannelID = channelID
    }

    public func accessToken() -> String? { active == nil ? nil : "fixture-token" }
}

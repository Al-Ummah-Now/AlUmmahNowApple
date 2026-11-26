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

    /// The person's name by the platform rule: the display name (aun-core already falls back to first + last name from
    /// the token), then the email. Never a handle, never the account id; nil when there is neither.
    public var name: String? {
        if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            return displayName
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty { return email }
        return nil
    }

    /// `name`, or the id where something must be shown (an avatar's initial, an accessibility value).
    public var label: String { name ?? id }
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
    private var signedInAt: Date
    private var hasSession = true
    private let stepUpAccount: StudioAccount?
    private var signOutError: (any Error)?
    private var switchError: (any Error)?
    private var requests = 0
    public private(set) var stepUpCount = 0

    /// `signedInAt`: the time of the last sign-in, as the token says it. `stepUpAccount`: who a fresh sign-in comes back as
    /// (by default the same person).
    public init(signedIn: [StudioAccount] = [], signedInAt: Date = Date(), stepUpAccount: StudioAccount? = nil) {
        stored = signedIn
        active = signedIn.first?.id
        self.signedInAt = signedInAt
        self.stepUpAccount = stepUpAccount
    }

    /// Makes signing out, or switching accounts, fail as a locked Keychain does.
    public func fail(signOut: (any Error)? = nil, switching: (any Error)? = nil) {
        signOutError = signOut
        switchError = switching
    }

    /// The refresh token is refused from now on, as a deleted account's is.
    public func revoke() { hasSession = false }

    public static let creator = StudioAccount(
        id: "fixture-creator", email: "yusuf.rahman@example.org", displayName: "Yusuf Rahman")

    public func accounts() -> [StudioAccount] { stored }
    public func activeAccount() -> StudioAccount? { stored.first { $0.id == active } }

    public func beginSignIn(_ prompt: SignInPrompt) -> SignInRequest {
        lastPrompt = prompt
        if case .stepUp = prompt { stepUpCount += 1 }
        requests += 1
        return SignInRequest(
            url: URL(string: "https://auth.fixtures.invalid/authorize?state=fixture-\(requests)")!,
            callbackScheme: Self.callbackScheme)
    }

    public func completeSignIn(redirect: URL) throws -> StudioAccount {
        signedInAt = Date()
        hasSession = true
        // A step-up signs the same person in again, unless it came back as someone else.
        if case .stepUp = lastPrompt {
            if let other = stepUpAccount {
                if !stored.contains(where: { $0.id == other.id }) { stored.append(other) }
                active = other.id
                return other
            }
            if let current = activeAccount() { return current }
        }
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
        if let switchError { throw switchError }
        guard let account = stored.first(where: { $0.id == id }) else { throw CoreError.notFound }
        active = id
        return account
    }

    public func signOut(_ id: String) throws {
        if let signOutError { throw signOutError }
        stored.removeAll { $0.id == id }
        if active == id { active = stored.first?.id }
    }

    public func setActiveChannel(_ channelID: String?) {
        guard let index = stored.firstIndex(where: { $0.id == active }) else { return }
        stored[index].activeChannelID = channelID
    }

    public func accessToken() -> String? {
        hasSession ? active.map { DeletionToken.fixture(accountID: $0, authTime: signedInAt) } : nil
    }
}

import AUNCoreBridge
import Foundation
import Observation

/// A message for the person, by L10n key.
public struct StudioNotice: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let key: String

    public init(_ key: String) { self.key = key }

    static func from(_ error: any Error) -> StudioNotice? {
        if (error as? CoreError) == .cancelled { return nil }
        return StudioNotice(StudioFailure.message(error).key)
    }
}

/// Signed-in accounts, the active one, and the channel Studio works in.
@MainActor @Observable
public final class StudioSession {
    public enum Phase: Equatable { case loading, signedOut, signedIn }
    public enum ChannelsState: Equatable { case idle, loading, loaded, failed }

    public private(set) var phase: Phase = .loading
    public private(set) var accounts: [StudioAccount] = []
    public private(set) var account: StudioAccount?
    /// Every channel the account can work in, owned first.
    public private(set) var allChannels: [StudioChannel] = []
    public private(set) var channelsState: ChannelsState = .idle
    public private(set) var channel: StudioChannel?
    public private(set) var isSigningIn = false
    public private(set) var isAddingPasskey = false
    public var notice: StudioNotice?
    /// An in-app message about a passkey sign-in or "Add a passkey".
    public var passkeyDialog: PasskeyDialog?
    /// The accounts sheet is open, so passkey dialogs present over it.
    var accountsOpen = false
    /// What the account may do as a creator; nil until read (or when the server cannot say).
    public private(set) var creator: CreatorAccess?
    /// A refusal that applies to the whole videos account (`videos_account_pending_deletion`, `videos_banned`).
    /// Studio shows it once, as a banner, instead of one error per action.
    public private(set) var accountState: Refusal?

    public let services: StudioServices
    /// Uploads of every account on this device; only the active account's run.
    public let uploads: UploadQueue
    private let authenticator: any WebAuthenticating
    private let passkeyAuthenticator: any PasskeyAuthenticating
    private let defaults: UserDefaults

    public init(
        services: StudioServices, authenticator: any WebAuthenticating,
        passkeyAuthenticator: any PasskeyAuthenticating = SystemPasskeyAuthenticator(),
        defaults: UserDefaults = .standard
    ) {
        self.services = services
        uploads = UploadQueue(services: services)
        self.authenticator = authenticator
        self.passkeyAuthenticator = passkeyAuthenticator
        self.defaults = defaults
        uploads.onAccountState = { [weak self] in self?.accountState = $0 }
    }

    /// Channels the person may upload to: the picker's list.
    public var channels: [StudioChannel] { allChannels.filter(\.canUpload) }

    public func start() async {
        do {
            accounts = try await services.accounts.accounts()
            account = try await services.accounts.activeAccount()
        } catch {
            AUNLog.studio.error("Reading accounts failed: \(error)")
        }
        phase = account == nil ? .signedOut : .signedIn
        uploads.accountID = account?.id
        if account != nil { await loadChannels() }
    }

    public func signIn(addingAccount: Bool = false) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let request = try await services.accounts.beginSignIn(addingAccount ? .addAccount : .standard)
            let redirect = try await authenticator.authenticate(request)
            let signedIn = try await services.accounts.completeSignIn(redirect: redirect)
            await adopt(signedIn)
        } catch {
            AUNLog.studio.error("Sign-in failed: \(error)")
            notice = StudioNotice.from(error)
        }
    }

    var passkeys: PasskeyFlow {
        PasskeyFlow(
            accounts: services.accounts, service: services.passkeys, authenticator: passkeyAuthenticator,
            web: authenticator, issuer: services.environment.authIssuer)
    }

    /// Signs in with a passkey from this device, a password manager, a phone or a security key (no browser).
    public func signInWithPasskey(addingAccount: Bool = false) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            await adopt(try await passkeys.signIn(addingAccount ? .addAccount : .standard))
        } catch {
            AUNLog.studio.error("Passkey sign-in failed: \(error)")
            passkeyDialog = PasskeyDialog.signInFailure(error, addingAccount: addingAccount)
        }
    }

    /// Adds a passkey to the active account. A sign-in older than the server allows asks to sign in again first.
    public func addPasskey() async {
        guard account != nil, !isAddingPasskey else { return }
        isAddingPasskey = true
        defer { isAddingPasskey = false }
        do {
            _ = try await passkeys.register()
            passkeyDialog = .added
        } catch {
            AUNLog.studio.error("Adding a passkey failed: \(error)")
            passkeyDialog = PasskeyDialog.registerFailure(error)
        }
    }

    /// Runs the follow-up a passkey dialog offered.
    public func perform(_ action: PasskeyDialog.Action) async {
        passkeyDialog = nil
        switch action {
        case .signInAnotherWay(let adding): await signIn(addingAccount: adding)
        case .signInAgain: await reauthenticateAndAddPasskey()
        }
    }

    private func reauthenticateAndAddPasskey() async {
        guard let current = account, !isAddingPasskey else { return }
        isAddingPasskey = true
        defer { isAddingPasskey = false }
        do {
            switch try await passkeys.reauthenticateAndRegister(accountID: current.id) {
            case .added:
                accounts = (try? await services.accounts.accounts()) ?? accounts
                passkeyDialog = .added
            case .otherAccount(let other):
                await adopt(other)
                passkeyDialog = .otherAccount(current.label)
            }
        } catch {
            AUNLog.studio.error("Adding a passkey after signing in again failed: \(error)")
            passkeyDialog = PasskeyDialog.registerFailure(error)
        }
    }

    public func switchAccount(to id: String) async {
        guard id != account?.id else { return }
        do {
            await adopt(try await services.accounts.switchAccount(to: id))
        } catch {
            notice = StudioNotice.from(error)
        }
    }

    /// Signs one account out of this device and revokes its refresh token. Other accounts stay signed in.
    public func signOut(_ id: String) async {
        uploads.discardJobs(of: id)
        do {
            try await services.accounts.signOut(id)
        } catch {
            AUNLog.studio.error("Sign-out failed: \(error)")
        }
        accounts = (try? await services.accounts.accounts()) ?? accounts.filter { $0.id != id }
        let next = try? await services.accounts.activeAccount()
        if let next {
            if next.id != account?.id { await adopt(next) }
        } else {
            account = nil
            uploads.accountID = nil
            creator = nil
            accountState = nil
            allChannels = []
            channel = nil
            channelsState = .idle
            phase = .signedOut
        }
    }

    public func select(_ channel: StudioChannel) async {
        self.channel = channel
        if let account { defaults.set(channel.id, forKey: Self.channelKey(account.id)) }
        do {
            try await services.accounts.setActiveChannel(channel.id)
        } catch {
            AUNLog.studio.error("Saving the active channel failed: \(error)")
        }
    }

    /// Reads `GET /api/me/creator`. Called after sign-in and whenever the app comes back to the foreground, so a
    /// restore by an admin lifts the account state without a relaunch.
    public func refreshCreatorAccess() async {
        guard account != nil else { return }
        do {
            let access = try await services.studio.creatorAccess()
            creator = access
            if access.pendingDeletion {
                accountState = Refusal(code: Refusal.accountPendingDeletion)
            } else if accountState?.code == Refusal.accountPendingDeletion {
                accountState = nil
                uploads.unblock()
            }
        } catch {
            AUNLog.studio.error("Reading creator access failed: \(error)")
        }
    }

    /// Records an account-wide refusal from any call; other errors are left to the screen that made the call.
    func note(_ error: any Error) {
        if let refusal = StudioFailure.accountState(error) { accountState = refusal }
    }

    public func loadChannels() async {
        channelsState = .loading
        do {
            allChannels = try await services.studio.channels()
            channelsState = .loaded
            channel = preferredChannel()
            await refreshCreatorAccess()
        } catch {
            AUNLog.studio.error("Loading channels failed: \(error)")
            channelsState = .failed
            if (error as? CoreError) == .signInRequired { notice = StudioNotice("studio.error.signIn") }
        }
    }

    private func adopt(_ next: StudioAccount) async {
        account = next
        uploads.accountID = next.id
        accounts = (try? await services.accounts.accounts()) ?? [next]
        phase = .signedIn
        allChannels = []
        channel = nil
        creator = nil
        accountState = nil
        uploads.unblock()
        await loadChannels()
    }

    /// The last channel picked on this device, then the account's active channel, the main channel, the first one.
    private func preferredChannel() -> StudioChannel? {
        let eligible = channels
        let remembered = account.flatMap { defaults.string(forKey: Self.channelKey($0.id)) }
        for id in [remembered, account?.activeChannelID].compactMap({ $0 }) {
            if let match = eligible.first(where: { $0.id == id }) { return match }
        }
        return eligible.first(where: \.isMain) ?? eligible.first
    }

    static func channelKey(_ accountID: String) -> String { "AUNStudioChannel.\(accountID)" }
}

import AUNCoreBridge
import Foundation
import Observation

/// A message for the person, by L10n key.
public struct StudioNotice: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let key: String

    public init(_ key: String) { self.key = key }

    static func from(_ error: any Error) -> StudioNotice? {
        switch error as? CoreError {
        case .cancelled: nil
        case .offline: StudioNotice("studio.error.offline")
        case .signInRequired: StudioNotice("studio.error.signIn")
        case .forbidden: StudioNotice("studio.error.forbidden")
        default: StudioNotice("studio.error.generic")
        }
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
    public var notice: StudioNotice?

    public let services: StudioServices
    private let authenticator: any WebAuthenticating
    private let defaults: UserDefaults

    public init(services: StudioServices, authenticator: any WebAuthenticating, defaults: UserDefaults = .standard) {
        self.services = services
        self.authenticator = authenticator
        self.defaults = defaults
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

    public func loadChannels() async {
        channelsState = .loading
        do {
            allChannels = try await services.studio.channels()
            channelsState = .loaded
            channel = preferredChannel()
        } catch {
            AUNLog.studio.error("Loading channels failed: \(error)")
            channelsState = .failed
            if (error as? CoreError) == .signInRequired { notice = StudioNotice("studio.error.signIn") }
        }
    }

    private func adopt(_ next: StudioAccount) async {
        account = next
        accounts = (try? await services.accounts.accounts()) ?? [next]
        phase = .signedIn
        allChannels = []
        channel = nil
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

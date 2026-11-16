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
        return StudioFailure.message(error).map { StudioNotice($0.key) }
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
    /// What the account may do as a creator; nil until read (or when the server cannot say).
    public private(set) var creator: CreatorAccess?
    /// A refusal that applies to the whole videos account (`videos_account_pending_deletion`, `videos_banned`).
    /// Studio shows it once, as a banner, instead of one error per action.
    public private(set) var accountState: Refusal?
    /// Which features the account sees in the current channel (`GET /api/me/features`); nil until the first read.
    /// While nil, or for a key the server leaves out, the feature is hidden (fail closed).
    public private(set) var features: UserFeatures?
    /// Sections a gated API answered 404 `feature_off` for, hidden until the account or channel changes.
    public private(set) var hiddenSections: Set<StudioLink.Section> = []
    /// The section a universal link asked for, until the shell shows it (`consumeLink`).
    public private(set) var linkedSection: StudioLink.Section?
    /// Changes with every link, so the same link opened twice still moves the shell.
    public private(set) var linkSerial = 0
    /// A link's channel that arrived before the channels were read.
    private var linkedChannelID: String?

    public let services: StudioServices
    /// Uploads of every account on this device; only the active account's run.
    public let uploads: UploadQueue
    private let authenticator: any WebAuthenticating
    private let defaults: UserDefaults

    public init(services: StudioServices, authenticator: any WebAuthenticating, defaults: UserDefaults = .standard) {
        self.services = services
        uploads = UploadQueue(services: services)
        self.authenticator = authenticator
        self.defaults = defaults
        uploads.onAccountState = { [weak self] in self?.accountState = $0 }
        uploads.onFeatureOff = { [weak self] in Task { await self?.refreshFeatures() } }
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
            features = nil
            hiddenSections = []
            accountState = nil
            allChannels = []
            channel = nil
            channelsState = .idle
            phase = .signedOut
        }
    }

    /// Opens a Studio address from a universal link (`/studio/<channel>/<section>`): its channel when the account can
    /// work in it, and its section. Links for other accounts' channels keep the current channel.
    public func open(_ link: StudioLink) async {
        linkedSection = link.section
        linkSerial += 1
        guard let id = link.channelID else { return }
        if let match = channels.first(where: { $0.id == id }) {
            if match.id != channel?.id { await select(match) }
        } else if channelsState != .loaded {
            linkedChannelID = id
        }
    }

    /// The shell has shown `linkedSection`.
    public func consumeLink() { linkedSection = nil }

    public func select(_ channel: StudioChannel) async {
        let changed = channel.id != self.channel?.id
        self.channel = channel
        if changed {
            hiddenSections = []
            await refreshFeatures()
        }
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

    /// Reads `GET /api/me/features` for the current channel, at the same moments as `refreshCreatorAccess`. A failed
    /// read keeps the last answer; with none, every gated entry stays hidden.
    public func refreshFeatures() async {
        guard account != nil else { return }
        do {
            features = try await services.studio.features(channelID: channel?.id)
        } catch {
            AUNLog.studio.error("Reading features failed: \(error)")
        }
    }

    /// Whether a gated feature is on for the account in the current channel.
    public func shows(_ feature: UserFeature) -> Bool { features?.isOn(feature) ?? false }

    /// The Upload tab (iPhone, iPad) and section (Mac): only with the `upload` feature.
    public var showsUpload: Bool { shows(.upload) }
    /// The Dashboard, unless every one of its sections is hidden; Studio then opens on Content.
    public var showsDashboard: Bool { !hiddenSections.contains(.home) }
    /// The Analytics tab and section, until its API answers `feature_off`.
    public var showsAnalytics: Bool { !hiddenSections.contains(.analytics) }

    /// A section's API answered 404 `feature_off`: hide the section and read the features again.
    public func featureOff(_ section: StudioLink.Section) {
        hiddenSections.insert(section)
        Task { await refreshFeatures() }
    }

    /// Records an account-wide refusal from any call; a feature that turned out to be off makes Studio read its features
    /// again. Other errors are left to the screen that made the call.
    func note(_ error: any Error) {
        if let refusal = StudioFailure.accountState(error) { accountState = refusal }
        if (error as? CoreError)?.hidesEntryPoint == true { Task { await refreshFeatures() } }
    }

    public func loadChannels() async {
        channelsState = .loading
        do {
            allChannels = try await services.studio.channels()
            channelsState = .loaded
            channel = preferredChannel()
            if let id = linkedChannelID {
                linkedChannelID = nil
                if let match = channels.first(where: { $0.id == id }) { channel = match }
            }
            await refreshCreatorAccess()
            await refreshFeatures()
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
        features = nil
        hiddenSections = []
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

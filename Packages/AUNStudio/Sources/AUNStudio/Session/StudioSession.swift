import AUNCoreBridge
import Foundation
import Observation

/// A message for the person, by L10n key.
public struct StudioNotice: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let key: String
    /// Says what went wrong; otherwise it only tells.
    public let isError: Bool
    /// Adds when the sign-in record of a deleted account is purged.
    public let purgeDays: Int?

    public init(_ key: String, isError: Bool = true, purgeDays: Int? = nil) {
        self.key = key
        self.isError = isError
        self.purgeDays = purgeDays
    }

    /// `DeletionBanner` shows these, in every state of every tab; screens with notices of their own leave them out.
    var isAboutDeletion: Bool { key.hasPrefix("studio.deleteAccount.") }

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
    public internal(set) var accounts: [StudioAccount] = []
    public private(set) var account: StudioAccount?
    /// Every channel the account can work in, owned first.
    public private(set) var allChannels: [StudioChannel] = []
    public private(set) var channelsState: ChannelsState = .idle
    public private(set) var channel: StudioChannel?
    public internal(set) var isSigningIn = false
    /// A deletion is running: accounts can't be switched, added or signed out meanwhile.
    public internal(set) var isDeletingAccount = false
    /// The deletions that started on this device and are not finished, of signed-in and signed-out accounts.
    public internal(set) var openDeletions: [DeletionRecord] = []
    public var notice: StudioNotice?
    /// What the account may do as a creator; nil until read (or when the server cannot say).
    public internal(set) var creator: CreatorAccess?
    /// The account and the Creator Terms (`CreatorTerms.swift`).
    public internal(set) var creatorTerms: CreatorTerms = .unknown
    /// The last Terms version the server gave this account, so a newer one can be called an update.
    var knownTermsVersion: String?
    /// Counts reads and agreements, so only the last one's answer counts.
    var termsTurn = 0
    /// Environment used for web/legal links.
    public var environment: AppEnvironment { services.environment }
    /// A refusal that applies to the whole videos account (`videos_account_pending_deletion`, `videos_banned`).
    /// Studio shows it once, as a banner, instead of one error per action.
    public internal(set) var accountState: Refusal?
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
    /// What was picked and not sent yet, in this window.
    let composer = UploadComposer()
    var isCheckingDeletions = false
    @ObservationIgnored var lastDeletionCheck: ContinuousClock.Instant?
    let authenticator: any WebAuthenticating
    let defaults: UserDefaults
    @ObservationIgnored private(set) lazy var deletion = AccountDeletion(
        records: services.deletionRecords, service: services.deletion, device: self)
    /// Other windows of this process on the same uploads (Mac): told when an account is gone.
    @ObservationIgnored private var removals: ObserverToken?

    public init(services: StudioServices, authenticator: any WebAuthenticating, defaults: UserDefaults = .standard) {
        self.services = services
        uploads = UploadQueue(services: services, defaults: defaults)
        self.authenticator = authenticator
        self.defaults = defaults
        uploads.onAccountState = { [weak self] in self?.accountState = $0 }
        uploads.onFeatureOff = { [weak self] in Task { await self?.refreshFeatures() } }
        uploads.onTermsRequired = { [weak self] accountID in self?.requireCreatorTerms(for: accountID) }
        removals = observeRemovedAccounts()
    }

    /// Channels the person may upload to: the picker's list.
    public var channels: [StudioChannel] { allChannels.filter(\.canUpload) }

    public func start() async {
        // Before anyone is shown: what an earlier run of the app left of a deletion.
        await settleDeletions()
        await refreshAccounts()
        account = await nextActiveAccount()
        phase = account == nil ? .signedOut : .signedIn
        uploads.accountID = account?.id
        composer.accountID = account?.id
        if account != nil { await loadChannels() }
    }

    public func signIn(addingAccount: Bool = false) async {
        guard !isSigningIn, !isDeletingAccount else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let request = try await services.accounts.beginSignIn(addingAccount ? .addAccount : .standard)
            let redirect = try await authenticator.authenticate(request)
            let signedIn = try await services.accounts.completeSignIn(redirect: redirect)
            accountIsLive(signedIn.id)
            await adopt(signedIn)
        } catch {
            AUNLog.studio.error("Sign-in failed: \(error)")
            notice = StudioNotice.from(error)
        }
    }

    public func switchAccount(to id: String) async {
        guard !isDeletingAccount, id != account?.id else { return }
        do {
            await adopt(try await services.accounts.switchAccount(to: id))
        } catch {
            notice = StudioNotice.from(error)
        }
    }

    /// Signs one account out of this device and revokes its refresh token. Other accounts stay signed in.
    public func signOut(_ id: String) async {
        guard !isDeletingAccount else { return }
        uploads.discardJobs(of: id)
        composer.discard(of: id)
        do {
            try await services.accounts.signOut(id)
        } catch {
            AUNLog.studio.error("Sign-out failed: \(error)")
        }
        await showRemaining(without: id)
    }

    /// After an account left this device: the next one, or signed out.
    func showRemaining(without id: String) async {
        accounts = accounts.filter { $0.id != id }
        await refreshAccounts()
        if let next = await nextActiveAccount() {
            if next.id != account?.id { await adopt(next) }
        } else {
            resetSignedOut()
        }
    }

    func resetSignedOut() {
        account = nil
        uploads.accountID = nil
        composer.accountID = nil
        creator = nil
        forgetTerms()
        features = nil
        hiddenSections = []
        accountState = nil
        allChannels = []
        channel = nil
        channelsState = .idle
        phase = .signedOut
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
            await probeAnalytics()
        }
        if let account { defaults.set(channel.id, forKey: Self.channelKey(account.id)) }
        do {
            try await services.accounts.setActiveChannel(channel.id)
        } catch {
            AUNLog.studio.error("Saving the active channel failed: \(error)")
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

    /// Analytics has no key in `/api/me/features`: ask its API once per channel (a one-day range) so an Analytics tab
    /// that is off never shows, not only after someone opens it. Other failures leave the tab to its own screen.
    func probeAnalytics() async {
        guard let id = channel?.id else { return }
        let end = Date()
        do {
            _ = try await services.studio.channelStats(
                channelID: id, period: DateInterval(start: end.addingTimeInterval(-86_400), end: end))
        } catch let error as CoreError where error == .featureOff {
            if channel?.id == id { hiddenSections.insert(.analytics) }
        } catch {
            AUNLog.studio.error("Checking Analytics failed: \(error)")
        }
    }

    /// A section's API answered 404 `feature_off`: hide the section and read the features again.
    public func featureOff(_ section: StudioLink.Section) {
        hiddenSections.insert(section)
        Task { await refreshFeatures() }
    }

    /// Records an account-wide refusal from any call; a feature that turned out to be off makes Studio read its features
    /// again. Other errors are left to the screen that made the call.
    func note(_ error: any Error, forAccount accountID: String? = nil) {
        if let refusal = StudioFailure.accountState(error) { accountState = refusal }
        if (error as? CoreError)?.refusal?.code == Refusal.termsRequired { requireCreatorTerms(for: accountID) }
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
            await probeAnalytics()
        } catch {
            AUNLog.studio.error("Loading channels failed: \(error)")
            channelsState = .failed
            if (error as? CoreError) == .signInRequired { notice = StudioNotice("studio.error.signIn") }
        }
    }

    func adopt(_ next: StudioAccount) async {
        account = next
        uploads.clearPendingPurge(for: next.id)
        uploads.accountID = next.id
        composer.accountID = next.id
        await refreshAccounts()
        if !accounts.contains(where: { $0.id == next.id }) { accounts.append(next) }
        phase = .signedIn
        allChannels = []
        channel = nil
        creator = nil
        forgetTerms()
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

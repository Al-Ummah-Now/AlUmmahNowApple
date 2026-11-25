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
    public enum CreatorTermsState: Equatable { case loading, failed, required, accepted }

    public private(set) var phase: Phase = .loading
    public private(set) var accounts: [StudioAccount] = []
    public private(set) var account: StudioAccount?
    /// Every channel the account can work in, owned first.
    public private(set) var allChannels: [StudioChannel] = []
    public private(set) var channelsState: ChannelsState = .idle
    public private(set) var channel: StudioChannel?
    public private(set) var isSigningIn = false
    /// Account whose Creator Terms acceptance POST is currently in flight (nil when idle or after switching accounts).
    private var acceptingTermsAccountID: String?
    public var isAcceptingTerms: Bool { acceptingTermsAccountID != nil && acceptingTermsAccountID == account?.id }
    public var notice: StudioNotice?
    /// Dedicated notice for CreatorTermsGateView so Terms errors/clears never clobber unrelated notices or double-announce.
    public var termsNotice: StudioNotice?
    /// What the account may do as a creator; nil until read (or when the server cannot say).
    public private(set) var creator: CreatorAccess?
    /// State of Creator Terms acceptance: only an explicit `.required` gates Upload; loading/failed let the server decide.
    public private(set) var creatorTermsState: CreatorTermsState = .loading
    /// Latest Creator Terms version reported by the server (`GET /api/me/creator` or 409 `currentVersion`).
    public private(set) var termsVersion: String?
    /// Incremented whenever the active Terms version changes while the gate is open (or on 409) so the checkbox resets.
    public private(set) var termsVersionBumpSerial = 0
    /// True after a 409 `terms_version_changed` or a known version bump while the gate is open (survives Dismiss / errors).
    public private(set) var termsUpdatedWhileOpen = false
    private var termsGeneration = 0
    private var uploadRefusalResumeCount = 0
    /// Environment used for web/legal links.
    public var environment: AppEnvironment { services.environment }
    /// True when the server explicitly reported that this account has not yet accepted the Creator Terms.
    public var needsCreatorTerms: Bool { creatorTermsState == .required }
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
        uploads.onTermsRequired = { [weak self] accountID in self?.requireCreatorTerms(for: accountID) }
        uploads.onUploadSucceeded = { [weak self] in self?.uploadRefusalResumeCount = 0 }
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
            termsGeneration += 1
            uploadRefusalResumeCount = 0
            acceptingTermsAccountID = nil
            creatorTermsState = .loading
            termsVersion = nil
            termsVersionBumpSerial = 0
            termsUpdatedWhileOpen = false
            termsNotice = nil
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

    private func adopt(_ next: StudioAccount) async {
        account = next
        uploads.accountID = next.id
        accounts = (try? await services.accounts.accounts()) ?? [next]
        phase = .signedIn
        allChannels = []
        channel = nil
        creator = nil
        termsGeneration += 1
        uploadRefusalResumeCount = 0
        acceptingTermsAccountID = nil
        creatorTermsState = .loading
        termsVersion = nil
        termsVersionBumpSerial = 0
        termsUpdatedWhileOpen = false
        termsNotice = nil
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

extension StudioSession {
    /// Reopens the Creator Terms gate for `accountID` (e.g. after a `403 terms_required` upload refusal).
    /// Always re-reads `GET /api/me/creator` so a newer Terms version is shown before the creator taps Agree.
    /// Ignores late refusals from another account and never cancels an in-flight Agree POST for the active account.
    public func requireCreatorTerms(for accountID: String? = nil) {
        if let accountID, account?.id != accountID { return }
        if !isAcceptingTerms { termsGeneration += 1 }
        creatorTermsState = .required
        if !isAcceptingTerms {
            Task { await refreshCreatorAccess(fromUploadRefusal: true) }
        }
    }

    /// Records acceptance of the Creator Terms & Community Guidelines on the server (`POST /api/me/creator/terms`).
    /// Never reads a version and posts it in the same tap, and never falls back to `termsVersion` when `shownVersion` is nil.
    @discardableResult
    public func acceptCreatorTerms(shownVersion: String?) async -> Bool {
        guard !isAcceptingTerms, let targetAccountID = account?.id else { return false }
        termsGeneration += 1
        let generation = termsGeneration
        acceptingTermsAccountID = targetAccountID
        defer {
            if acceptingTermsAccountID == targetAccountID && termsGeneration == generation {
                acceptingTermsAccountID = nil
            }
        }
        do {
            let candidate = shownVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let version = candidate, !version.isEmpty else {
                return try await fetchVersionWithoutPosting(targetAccountID: targetAccountID, generation: generation)
            }
            try await services.studio.acceptCreatorTerms(version: version)
            guard isCurrentTermsCall(accountID: targetAccountID, generation: generation) else { return false }
            creator?.termsAccepted = true
            termsVersion = version
            uploadRefusalResumeCount = 0
            completeCreatorTermsAcceptance(for: targetAccountID)
            return true
        } catch {
            return handleAcceptTermsError(error, targetAccountID: targetAccountID, generation: generation)
        }
    }

    /// Reads `GET /api/me/creator`. Called after sign-in, on foreground return, and after `403 terms_required`.
    public func refreshCreatorAccess(fromUploadRefusal: Bool = false) async {
        guard let targetAccountID = account?.id, !isAcceptingTerms else { return }
        let generation = termsGeneration
        // Keep `.required` steady across foreground returns (e.g. after reading Terms in Safari) so the checkbox is not wiped.
        if creatorTermsState != .accepted && creatorTermsState != .required { creatorTermsState = .loading }
        do {
            let access = try await services.studio.creatorAccess()
            guard account?.id == targetAccountID, termsGeneration == generation, !isAcceptingTerms else { return }
            applyCreatorAccess(access, for: targetAccountID, fromUploadRefusal: fromUploadRefusal)
        } catch {
            guard account?.id == targetAccountID, termsGeneration == generation, !isAcceptingTerms else { return }
            AUNLog.studio.error("Reading creator access failed: \(error)")
            if creatorTermsState != .accepted && creatorTermsState != .required { creatorTermsState = .failed }
        }
    }

    private func applyCreatorAccess(_ access: CreatorAccess, for targetAccountID: String, fromUploadRefusal: Bool) {
        let previousVersion = termsVersion
        let wasRequired = creatorTermsState == .required
        creator = access
        if let incoming = access.termsVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !incoming.isEmpty {
            termsVersion = incoming
        }
        if access.termsAccepted == false {
            creatorTermsState = .required
            if wasRequired, let latest = termsVersion, !latest.isEmpty, latest != previousVersion {
                termsVersionBumpSerial += 1
                if previousVersion != nil {
                    termsUpdatedWhileOpen = true
                    termsNotice = StudioNotice("studio.terms.versionChanged")
                } else if termsNotice?.key == "studio.error.generic" {
                    termsNotice = nil
                }
            } else if termsVersion != nil, termsNotice?.key == "studio.error.generic" {
                termsNotice = nil
            }
        } else if access.termsAccepted == nil && fromUploadRefusal {
            // Do not unblock jobs on a nil answer to a 403-triggered read (avoids a 403 -> nil -> unblock -> 403 loop).
            creatorTermsState = .required
            termsNotice = StudioNotice("studio.error.generic")
        } else if fromUploadRefusal {
            // Bound automatic resume when a 403-triggered read says termsAccepted == true (e.g. mixed isolates mid-deploy).
            if uploadRefusalResumeCount < 2 {
                uploadRefusalResumeCount += 1
                completeCreatorTermsAcceptance(for: targetAccountID)
            } else {
                creatorTermsState = .required
                termsNotice = StudioNotice("studio.error.generic")
            }
        } else {
            uploadRefusalResumeCount = 0
            completeCreatorTermsAcceptance(for: targetAccountID)
        }
        applyPendingDeletionState(access.pendingDeletion)
    }

    private func applyPendingDeletionState(_ pendingDeletion: Bool) {
        if pendingDeletion {
            accountState = Refusal(code: Refusal.accountPendingDeletion)
        } else if accountState?.code == Refusal.accountPendingDeletion {
            accountState = nil
            uploads.unblock()
        }
    }

    private func isCurrentTermsCall(accountID: String, generation: Int) -> Bool {
        account?.id == accountID && termsGeneration == generation
    }

    private func completeCreatorTermsAcceptance(for accountID: String) {
        creatorTermsState = .accepted
        termsUpdatedWhileOpen = false
        termsNotice = nil
        uploads.unblockTerms(forAccount: accountID)
    }

    /// Fetches the current version to display without posting acceptance in the same tap.
    /// Because this is triggered by an explicit tap, `termsAccepted != false` (true or nil / feature off) unblocks cleanly.
    private func fetchVersionWithoutPosting(targetAccountID: String, generation: Int) async throws -> Bool {
        let previousVersion = termsVersion
        let access = try await services.studio.creatorAccess()
        guard isCurrentTermsCall(accountID: targetAccountID, generation: generation) else { return false }
        creator = access
        if let incoming = access.termsVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !incoming.isEmpty {
            termsVersion = incoming
        }
        if access.termsAccepted != false {
            uploadRefusalResumeCount = 0
            completeCreatorTermsAcceptance(for: targetAccountID)
            return true
        }
        if let fetched = access.termsVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !fetched.isEmpty {
            creatorTermsState = .required
            termsVersion = fetched
            termsVersionBumpSerial += 1
            if previousVersion != nil && fetched != previousVersion {
                termsUpdatedWhileOpen = true
                termsNotice = StudioNotice("studio.terms.versionChanged")
            } else if termsNotice?.key == "studio.error.generic" {
                termsNotice = nil
            }
            return false
        }
        creatorTermsState = .required
        termsNotice = StudioNotice("studio.error.generic")
        return false
    }

    private func handleAcceptTermsError(_ error: any Error, targetAccountID: String, generation: Int) -> Bool {
        guard isCurrentTermsCall(accountID: targetAccountID, generation: generation) else { return false }
        if (error as? CoreError) == .featureOff {
            creator?.termsAccepted = nil
            termsVersion = nil
            completeCreatorTermsAcceptance(for: targetAccountID)
            return true
        }
        if case .refused(let refusal) = error as? CoreError, refusal.code == Refusal.termsVersionChanged {
            if let latest = refusal.currentVersion, !latest.isEmpty {
                termsVersion = latest
                creator?.termsVersion = latest
            }
            termsVersionBumpSerial += 1
            termsUpdatedWhileOpen = true
            creatorTermsState = .required
            termsNotice = StudioNotice("studio.terms.versionChanged")
            return false
        }
        AUNLog.studio.error("Accepting creator terms failed: \(error)")
        termsNotice = StudioNotice.from(error)
        return false
    }
}

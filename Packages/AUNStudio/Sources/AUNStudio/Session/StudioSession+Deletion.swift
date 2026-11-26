import AUNCoreBridge
import Foundation

/// Account deletion in the session: what this device keeps of an account (`DeletionDevice`), the records that are open, and
/// the fresh sign-in. `AccountDeletion` is the flow, `DeleteAccountModel` the dialog.
extension StudioSession {
    static let accountRemoved = Notification.Name("AUNStudioAccountRemoved")

    /// Number of channels the active account owns, once channels are loaded (nil while loading or failed).
    public var ownedChannelCount: Int? {
        channelsState == .loaded ? allChannels.filter { $0.role == .owner }.count : nil
    }

    /// The open deletion of an account, if any.
    public func openDeletion(of accountID: String?) -> DeletionRecord? {
        openDeletions.first { $0.accountID == accountID }
    }

    /// The open deletions of accounts that are not signed in here.
    public var signedOutDeletions: [DeletionRecord] {
        openDeletions.filter { record in !accounts.contains { $0.id == record.accountID } }
    }

    // MARK: Records

    /// Finishes what is finished and shows what is open. Run at start. The accounts that are gone.
    @discardableResult
    func settleDeletions() async -> [String] {
        var gone: [String] = []
        do {
            for settled in try await deletion.settle() {
                switch settled {
                case .deleted(let record):
                    gone.append(record.accountID)
                    notice = Self.deletedNotice(
                        leftover: record.leftover, contentErased: record.stage >= .contentErased)
                case .cleaned(let record): gone.append(record.accountID)
                case .open(let record): uploads.release(record.accountID)
                // Nothing is uploaded for an account that may be gone.
                case .unknown(let record): try? await uploads.hold(record.accountID)
                }
            }
        } catch {
            AUNLog.studio.error("Deletion records unreadable: \(error)")
        }
        refreshDeletions()
        return gone
    }

    /// Asks what became of a deletion whose answer was lost, once the app runs. `asked`: the person did, so they are told
    /// when it is still not known.
    public func checkDeletions(asked: Bool = false) async {
        guard !isDeletingAccount, !isSigningIn, !isCheckingDeletions else { return }
        // By itself at most once a minute.
        if !asked, let last = lastDeletionCheck, ContinuousClock.now - last < .seconds(60) { return }
        lastDeletionCheck = .now
        isCheckingDeletions = true
        defer { isCheckingDeletions = false }
        if asked { notice = nil }
        for id in await settleDeletions() where accounts.contains(where: { $0.id == id }) {
            composer.discard(of: id)
            await showRemaining(without: id)
            tellOtherWindows(id)
        }
        if asked, notice == nil, openDeletions.contains(where: { $0.stage == .deleteSent }) {
            notice = StudioNotice("studio.deleteAccount.stillUnknown")
        }
    }

    /// On the sign-in screen: the person settles a deletion nothing is left to ask about. The account itself is not touched.
    public func dismissDeletion(of accountID: String) {
        guard let record = openDeletion(of: accountID), record.unsettled else { return }
        try? services.deletionRecords.remove(accountID)
        uploads.release(accountID)
        refreshDeletions()
    }

    func refreshDeletions() {
        do {
            openDeletions = try services.deletionRecords.all().filter { $0.stage.started && $0.stage != .deleted }
        } catch {
            AUNLog.studio.error("Deletion records unreadable: \(error)")
        }
    }

    /// Accounts whose deletion is done: never shown, also while something of them could not be removed from this device.
    private var deletedAccounts: Set<String> {
        let records = (try? services.deletionRecords.all()) ?? []
        return Set(records.filter { $0.stage == .deleted }.map(\.accountID))
    }

    func refreshAccounts() async {
        do {
            let gone = deletedAccounts
            accounts = try await services.accounts.accounts().filter { !gone.contains($0.id) }
        } catch {
            AUNLog.studio.error("Reading accounts failed: \(error)")
        }
    }

    /// The active account; if that one is deleted, the next that is not.
    func nextActiveAccount() async -> StudioAccount? {
        do {
            guard let active = try await services.accounts.activeAccount() else { return nil }
            if !deletedAccounts.contains(active.id) { return active }
            guard let next = accounts.first(where: { $0.id != active.id }) else { return nil }
            return try await services.accounts.switchAccount(to: next.id)
        } catch {
            AUNLog.studio.error("Reading the active account failed: \(error)")
            return nil
        }
    }

    /// A sign-in of the account just worked, so it exists: a finished deletion of it belongs to the past (staff restored it).
    func accountIsLive(_ accountID: String) {
        guard let record = try? services.deletionRecords.all().first(where: { $0.accountID == accountID }),
            record.stage >= .deleteSent
        else { return }
        if record.stage == .deleted {
            try? services.deletionRecords.remove(accountID)
        } else {
            var open = record
            open.stage = .contentErased
            try? services.deletionRecords.save(open)
            uploads.release(accountID)
        }
        refreshDeletions()
    }

    // MARK: End

    /// What the person is told once the account is gone.
    static func deletedNotice(leftover: Set<DeletionLeftover>, contentErased: Bool) -> StudioNotice {
        let key =
            if !contentErased {
                "studio.deleteAccount.doneElsewhere"
            } else if leftover.isEmpty {
                "studio.deleteAccount.done"
            } else if leftover == [.channel] {
                "studio.deleteAccount.doneChannel"
            } else if leftover == [.other] {
                "studio.deleteAccount.doneOther"
            } else {
                "studio.deleteAccount.doneBoth"
            }
        return StudioNotice(key, isError: false, purgeDays: 30)
    }

    /// The account is gone: this window shows the next one, or signed out, and so do the others.
    func accountDeleted(_ accountID: String, leftover: Set<DeletionLeftover>, contentErased: Bool) async {
        refreshDeletions()
        composer.discard(of: accountID)
        await showRemaining(without: accountID)
        notice = Self.deletedNotice(leftover: leftover, contentErased: contentErased)
        tellOtherWindows(accountID)
    }

    private func tellOtherWindows(_ accountID: String) {
        NotificationCenter.default.post(
            name: Self.accountRemoved, object: self, userInfo: ["account": accountID, "uploads": uploads.store.url])
    }

    /// Other windows of this process on the same uploads (Mac) are told when an account is gone.
    func observeRemovedAccounts() -> ObserverToken {
        let name = Self.accountRemoved
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let account = note.userInfo?["account"] as? String
            let store = note.userInfo?["uploads"] as? URL
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let account, sender != ObjectIdentifier(self), store == self.uploads.store.url else { return }
                Task {
                    self.refreshDeletions()
                    self.composer.discard(of: account)
                    await self.showRemaining(without: account)
                }
            }
        }
        return ObserverToken(token)
    }

    // MARK: Fresh sign-in

    enum StepUp: Equatable {
        case same
        /// Someone else signed in. `restored`: the first account is active again.
        case other(restored: Bool)
        case cancelled
        case failed
    }

    /// A fresh sign-in of `accountID`, bound to its OAuth `state` and a short time. It removes nothing: the person confirms
    /// again. Uploads stand still meanwhile, so none of theirs asks for a token while someone else is active.
    func stepUp(for accountID: String) async -> StepUp {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await uploads.hold(accountID)
        } catch {
            AUNLog.studio.error("Uploads not held, so no sign-in for a deletion: \(error)")
            return .failed
        }
        defer { if openDeletion(of: accountID)?.stage != .deleteSent { uploads.release(accountID) } }
        let started = ContinuousClock.now
        do {
            let request = try await services.accounts.beginSignIn(.stepUp(maxAge: AccountDeletion.firstMaxAge))
            guard let state = OAuthState.of(request.url) else { return .failed }
            let redirect = try await authenticator.authenticate(request)
            guard OAuthState.of(redirect) == state, ContinuousClock.now - started < .seconds(300) else { return .failed }
            let signedIn = try await services.accounts.completeSignIn(redirect: redirect)
            accountIsLive(signedIn.id)
            if signedIn.id == accountID {
                await refreshAccounts()
                return .same
            }
            return .other(restored: await restore(accountID, from: signedIn))
        } catch {
            AUNLog.studio.error("Sign-in for a deletion failed: \(error)")
            return (error as? CoreError) == .cancelled ? .cancelled : .failed
        }
    }

    /// Makes the first account active again. When that fails, the app shows who really is.
    private func restore(_ accountID: String, from other: StudioAccount) async -> Bool {
        do {
            _ = try await services.accounts.switchAccount(to: accountID)
            await refreshAccounts()
            return true
        } catch {
            AUNLog.studio.error("Switching back failed: \(error)")
            await adopt(other)
            return false
        }
    }
}

extension StudioSession: DeletionDevice {
    public func session(of accountID: String) async throws -> DeletionSession {
        let active = try await services.accounts.activeAccount()
        guard let active else { return .none }
        guard active.id == accountID, account?.id == accountID else { return .otherAccount }
        guard !active.needsReauth, let token = try await services.accounts.accessToken() else { return .none }
        return .token(token)
    }

    public func holdUploads(of accountID: String) async throws { try await uploads.hold(accountID) }
    public func releaseUploads(of accountID: String) { uploads.release(accountID) }
    public func purgeUploads(of accountID: String) throws { try uploads.purgeJobs(of: accountID) }

    public func endSession(of accountID: String) async throws {
        guard try await services.accounts.accounts().contains(where: { $0.id == accountID }) else { return }
        try await services.accounts.signOut(accountID)
    }

    public func forgetChoices(of accountID: String) { defaults.removeObject(forKey: Self.channelKey(accountID)) }
}

/// Stops observing when it goes away.
final class ObserverToken {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

import AUNCoreBridge

/// What the server says about the account and the Creator Terms & Community Guidelines. Only `required` gates Upload:
/// while nothing is known, the server itself decides.
public enum CreatorTerms: Equatable, Sendable {
    /// Not read yet, or the read failed.
    case unknown
    /// The server says nothing about the Terms: its `creatorTerms` switch is off, or it predates them.
    case off
    case accepted
    case required(Gate)

    /// The gate while the Terms wait for an agreement. One value, so a tick and the version it is for change together.
    public struct Gate: Equatable, Sendable {
        /// The version the person is shown and agrees to; nil while it could not be read, and then none is accepted.
        public private(set) var version: String?
        /// The Terms changed since a version this account was known to have.
        public private(set) var updated: Bool
        /// The checkbox, for `version`.
        public var agreed = false
        /// The agreement is being saved.
        public var saving = false
        public var message: Message?

        public init(version: String?, updated: Bool = false, message: Message? = nil) {
            self.version = version
            self.updated = updated
            self.message = message
        }

        /// The server answered, with `current` as its version (nil: it gave none, and the one shown stays). Another
        /// version needs a new tick, and says why the box was cleared. `known` is the last version the server gave.
        public mutating func read(_ current: String?, known: String?) {
            if case .notRead = message { message = nil }
            guard let current, current != version else { return }
            if let before = version ?? known, before != current {
                updated = true
                message = .updated
            } else {
                message = agreed ? .loaded : nil
            }
            version = current
            agreed = false
        }

        /// The server did not take the agreement because the Terms are newer (`409`); `current` is nil when it did not
        /// say which version they are, and the next agreement reads it first.
        public mutating func refuse(current: String?) {
            version = current
            updated = true
            agreed = false
            message = .updated
        }
    }

    /// What the gate tells the person, until they dismiss it or agree again.
    public enum Message: Equatable, Sendable {
        /// The Terms changed while the gate was open.
        case updated
        /// The first version was read after the box was ticked.
        case loaded
        /// The server could not be asked, or contradicted itself; gone with the next answer.
        case notRead(String)
        /// The agreement was not saved.
        case notSaved(String)

        public var key: String {
            switch self {
            case .updated: "studio.terms.versionChanged"
            case .loaded: "studio.terms.versionLoaded"
            case .notRead(let key), .notSaved(let key): key
            }
        }
    }

    public var gate: Gate? {
        if case .required(let gate) = self { gate } else { nil }
    }
}

extension StudioSession {
    /// The Terms wait for an agreement: Upload shows the gate.
    public var needsCreatorTerms: Bool { creatorTerms.gate != nil }
    public var isAcceptingTerms: Bool { creatorTerms.gate?.saving == true }

    /// Ticks or clears the checkbox.
    public func setTermsAgreed(_ agreed: Bool) {
        guard !isAcceptingTerms else { return }
        updateGate { $0.agreed = agreed }
    }

    public func dismissTermsMessage() {
        updateGate { $0.message = nil }
    }

    /// A `403 terms_required` for `accountID` (nil: the active one): opens the gate and asks the server, so a newer
    /// version is shown before the person agrees. A late refusal of another account is ignored.
    public func requireCreatorTerms(for accountID: String? = nil) {
        if let accountID, account?.id != accountID { return }
        guard account != nil else { return }
        if !needsCreatorTerms { creatorTerms = .required(.init(version: knownTermsVersion)) }
        Task { await refreshCreatorAccess(afterRefusal: true) }
    }

    /// Reads `GET /api/me/creator`: after sign-in, on return to the app, and after a `403 terms_required`. A failed read
    /// keeps what is known; an answer that a later read, an agreement or another account overtook is dropped.
    public func refreshCreatorAccess(afterRefusal: Bool = false) async {
        guard let accountID = account?.id, !isAcceptingTerms else { return }
        let turn = nextTermsTurn()
        do {
            let access = try await services.studio.creatorAccess()
            guard turn == termsTurn else { return }
            apply(access, for: accountID, afterRefusal: afterRefusal)
        } catch {
            AUNLog.studio.error("Reading creator access failed: \(error)")
        }
    }

    /// Records the agreement with the version the gate shows (`POST /api/me/creator/terms`). Without one, it only reads
    /// and shows the current version: a version nobody was shown is never sent. Returns whether Upload is open.
    @discardableResult
    public func acceptCreatorTerms() async -> Bool {
        guard let accountID = account?.id, let gate = creatorTerms.gate, gate.agreed, !gate.saving else { return false }
        let turn = nextTermsTurn()
        updateGate {
            $0.saving = true
            $0.message = nil
        }
        do {
            if let version = gate.version {
                try await services.studio.acceptCreatorTerms(version: version)
                guard turn == termsTurn else { return false }
                creator?.termsAccepted = true
                settle(.accepted, for: accountID)
            } else {
                let access = try await services.studio.creatorAccess()
                guard turn == termsTurn else { return false }
                updateGate { $0.saving = false }
                apply(access, for: accountID, afterRefusal: false)
                updateGate { if $0.version == nil { $0.message = .notRead("studio.error.generic") } }
            }
        } catch {
            guard turn == termsTurn else { return false }
            notAccepted(error, version: gate.version, for: accountID)
        }
        return !needsCreatorTerms
    }

    private func notAccepted(_ error: any Error, version: String?, for accountID: String) {
        // The switch was turned off meanwhile: nothing to agree to.
        if (error as? CoreError) == .featureOff {
            creator?.termsAccepted = nil
            settle(.off, for: accountID)
            return
        }
        if let refusal = (error as? CoreError)?.refusal, refusal.code == Refusal.termsVersionChanged {
            if let current = refusal.currentVersion { knownTermsVersion = current }
            updateGate {
                $0.saving = false
                $0.refuse(current: refusal.currentVersion)
            }
            return
        }
        AUNLog.studio.error("Accepting creator terms failed: \(error)")
        let key = StudioNotice.from(error)?.key
        updateGate {
            $0.saving = false
            $0.message = key.map { version == nil ? .notRead($0) : .notSaved($0) }
        }
    }

    private func apply(_ access: CreatorAccess, for accountID: String, afterRefusal: Bool) {
        creator = access
        let known = knownTermsVersion
        let current = access.termsVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        knownTermsVersion = current ?? known
        switch access.termsAccepted {
        case false:
            if needsCreatorTerms {
                updateGate { $0.read(current, known: known) }
            } else {
                let updated = known != nil && knownTermsVersion != known
                creatorTerms = .required(.init(version: knownTermsVersion, updated: updated))
            }
        case nil where afterRefusal:
            // Refused, yet the server says nothing about the Terms: resuming now could go round and round.
            contradicted(current, known: known)
        case true where afterRefusal:
            let resumed = uploads.unblockTerms(forAccount: accountID, automatic: true)
            // Accepted, yet an upload is refused again and again (servers that disagree during a rollout).
            if resumed { creatorTerms = .accepted } else { contradicted(current, known: known) }
        case true: settle(.accepted, for: accountID)
        default: settle(.off, for: accountID)
        }
        if access.pendingDeletion {
            accountState = Refusal(code: Refusal.accountPendingDeletion)
        } else if accountState?.code == Refusal.accountPendingDeletion {
            accountState = nil
            uploads.unblock()
        }
    }

    /// The server's answers do not agree: the gate says that something went wrong, and agreeing asks again.
    private func contradicted(_ current: String?, known: String?) {
        if !needsCreatorTerms { creatorTerms = .required(.init(version: knownTermsVersion)) }
        updateGate {
            $0.read(current, known: known)
            $0.message = .notRead("studio.error.generic")
        }
    }

    /// Nothing is left to agree to: Upload is open and the uploads that waited go on.
    private func settle(_ terms: CreatorTerms, for accountID: String) {
        creatorTerms = terms
        uploads.unblockTerms(forAccount: accountID)
    }

    private func updateGate(_ change: (inout CreatorTerms.Gate) -> Void) {
        guard case .required(var gate) = creatorTerms else { return }
        change(&gate)
        creatorTerms = .required(gate)
    }

    /// Another account (or none): nothing is known about the Terms, and answers still on their way are dropped.
    func forgetTerms() {
        nextTermsTurn()
        creatorTerms = .unknown
        knownTermsVersion = nil
    }

    @discardableResult
    private func nextTermsTurn() -> Int {
        termsTurn += 1
        return termsTurn
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

import AUNCoreBridge
import Foundation
import Observation

/// The dialog that deletes an account: what its action does now, and what it says. A sign-in never starts a deletion; the
/// person confirms again after it. One is made each time the dialog opens, so nothing of an earlier answer is left.
@MainActor @Observable
public final class DeleteAccountModel {
    public enum Action: Equatable {
        case delete
        /// Asks for a recent sign-in first; nothing is removed by it.
        case signIn
        /// After what stays behind was said.
        case deleteAnyway
    }

    /// What happened, told outside the dialog, which closes.
    public enum End: Equatable { case deleted, otherAccount }

    public let account: StudioAccount
    public private(set) var working = false
    /// The person asked to stop: the request that is out ends first.
    public private(set) var stopping = false
    /// Passes that left more to remove.
    public private(set) var passes = 0
    public private(set) var restarted = false
    public private(set) var action: Action = .delete
    /// L10n key of what the dialog says now.
    public private(set) var message: String?
    /// `message` says what went wrong.
    public private(set) var isError = false
    /// Not before then (the server asked).
    public private(set) var notBefore: Date?
    public private(set) var end: End?
    /// What the person was told stays, which is all that going on accepts.
    private(set) var leftover: Set<DeletionLeftover> = []

    private let session: StudioSession

    public init(account: StudioAccount, session: StudioSession) {
        self.account = account
        self.session = session
    }

    /// Cancel closes the dialog; while a request is out it asks to stop instead (that request has a limited time).
    /// True when the dialog may close.
    public func cancel() -> Bool {
        if working { stopping = true }
        return !working
    }

    /// Whether the action may be used: the word typed (a sign-in needs none), nothing running, no wait left.
    public func canAct(typed: String, now: Date = Date()) -> Bool {
        guard !working, !session.isSigningIn, !(notBefore.map { $0 > now } ?? false) else { return false }
        return action == .signIn || DeleteWord.matches(typed)
    }

    public func act() async {
        guard !working, !session.isDeletingAccount, !session.isSigningIn else { return }
        if action == .signIn { await signIn() } else { await delete() }
    }

    private func delete() async {
        working = true
        session.isDeletingAccount = true
        stopping = false
        passes = 0
        restarted = false
        message = nil
        isError = false
        let outcome = await session.deletion.run(
            account.id, label: account.email ?? account.label, accepting: action == .deleteAnyway ? leftover : [],
            stopRequested: { stopping },
            onPass: { pass, again in
                passes = pass
                restarted = restarted || again
            })
        session.isDeletingAccount = false
        working = false
        stopping = false
        session.refreshDeletions()
        await show(outcome)
    }

    private func show(_ outcome: DeletionOutcome) async {
        switch outcome {
        case .deleted(let leftover, let contentErased):
            await session.accountDeleted(account.id, leftover: leftover, contentErased: contentErased)
            end = .deleted
        case .needsSignIn(let erased):
            action = .signIn
            message = Self.signInText(erased)
        case .otherAccount(let erased):
            fail(erased == .nothing ? "studio.deleteAccount.otherAccount" : "studio.deleteAccount.otherAccountStarted")
        case .leftBehind(let left):
            action = .deleteAnyway
            leftover = left
            message =
                left == [.channel]
                ? "studio.deleteAccount.leftChannel"
                : left == [.other] ? "studio.deleteAccount.leftOther" : "studio.deleteAccount.leftBoth"
        case .wait(let until, let erased):
            fail(erased == .nothing ? "studio.deleteAccount.busyNothing" : "studio.deleteAccount.wait")
            notBefore = until
        case .paused(let stopped, let erased):
            if stopped {
                fail(erased == .nothing ? "studio.deleteAccount.stoppedNothing" : "studio.deleteAccount.stopped")
            } else {
                fail("studio.deleteAccount.more")
            }
        case .failed(let erased): fail(Self.failedText(erased))
        case .unknown: fail("studio.deleteAccount.errorUnknown")
        case .noRecord(let erased):
            fail(erased == .nothing ? "studio.deleteAccount.errorNothing" : "studio.deleteAccount.unavailable")
        }
    }

    private static func failedText(_ erased: ErasedSoFar) -> String {
        switch erased {
        case .nothing: "studio.deleteAccount.errorNothing"
        case .some: "studio.deleteAccount.errorStarted"
        case .content: "studio.deleteAccount.errorContentErased"
        }
    }

    private func fail(_ key: String) {
        action = .delete
        message = key
        isError = true
    }

    private static func signInText(_ erased: ErasedSoFar) -> String {
        switch erased {
        case .nothing: "studio.deleteAccount.signIn"
        case .some: "studio.deleteAccount.signInStarted"
        case .content: "studio.deleteAccount.signInContentErased"
        }
    }

    private func signIn() async {
        switch await session.stepUp(for: account.id) {
        case .same:
            action = .delete
            message = "studio.deleteAccount.signedInAgain"
            isError = false
        case .other(let restored):
            let started = session.openDeletion(of: account.id) != nil
            session.notice = StudioNotice(
                restored
                    ? started ? "studio.deleteAccount.signedInOtherStarted" : "studio.deleteAccount.signedInOther"
                    : "studio.deleteAccount.signedInOtherStays")
            end = .otherAccount
        case .cancelled, .failed:
            message = "studio.deleteAccount.signInFailed"
            isError = true
        }
    }
}

/// The typed word: either one in either language, because a keyboard may have only one of them. Letter case, spaces around
/// it, and Arabic vowel marks, tatweel and direction marks anywhere in it don't count.
enum DeleteWord {
    static func matches(_ typed: String) -> Bool {
        let kept = typed.unicodeScalars.filter { scalar in
            if scalar.value == 0x0640 || scalar.properties.generalCategory == .format { return false }
            return !(scalar.properties.generalCategory == .nonspacingMark && isArabic(scalar))
        }
        let word = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return word.caseInsensitiveCompare("DELETE") == .orderedSame || word == "حذف"
    }

    private static func isArabic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0600...0x06FF).contains(scalar.value) || (0x0750...0x077F).contains(scalar.value)
            || (0x08A0...0x08FF).contains(scalar.value)
    }
}

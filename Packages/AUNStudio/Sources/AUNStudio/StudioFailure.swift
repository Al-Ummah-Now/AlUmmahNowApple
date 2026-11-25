import AUNCoreBridge
import Foundation

/// The one place an error becomes text (an L10n key and its values), so every screen says the same thing.
enum StudioFailure {
    /// The text for an error, or nil when there is nothing to say: a feature that is off, not configured or not in the
    /// person's tier (`feature_off`, 402, `upgrade_required`) hides its entry point instead (owner rule 2026-11-16).
    static func message(_ error: any Error) -> (key: String, values: [String])? {
        if let core = error as? CoreError, core.hidesEntryPoint {
            AUNLog.studio.info("Hidden: the server says this feature is off for the account")
            return nil
        }
        return switch error as? CoreError {
        case .refused(let refusal): refusalMessage(refusal).map { ($0, []) } ?? ("studio.error.generic", [])
        case .offline: ("studio.error.offline", [])
        case .signInRequired: ("studio.error.signIn", [])
        case .forbidden: ("studio.error.forbidden", [])
        default: ("studio.error.generic", [])
        }
    }

    /// Plain facts for quotas and account states; nil for tier refusals, which hide instead of explaining.
    static func refusalMessage(_ refusal: Refusal) -> String? {
        if refusal.hidesEntryPoint { return nil }
        return switch refusal.code {
        case Refusal.channelLimit: "studio.refusal.channelLimit"
        case Refusal.uploadLimit: "studio.upload.error.limit"
        case Refusal.accountPendingDeletion: "studio.account.pendingDeletion"
        case Refusal.banned: "studio.account.banned"
        case Refusal.termsRequired: "studio.terms.title"
        case Refusal.termsVersionChanged: "studio.terms.versionChanged"
        default: "studio.error.generic"
        }
    }

    /// The refusal that applies to the whole account, if this error is one.
    static func accountState(_ error: any Error) -> Refusal? {
        if case .refused(let refusal) = error as? CoreError, refusal.isAccountState { return refusal }
        return nil
    }
}

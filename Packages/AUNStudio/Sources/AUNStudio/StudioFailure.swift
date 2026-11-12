import AUNCoreBridge
import Foundation

/// The one place an error becomes text (an L10n key and its values), so every screen says the same thing.
enum StudioFailure {
    /// Shows `values[0]` as is: a plan's own message (Q27-2), already in the reader's language.
    static let plainKey = "studio.plain"

    static func message(_ error: any Error) -> (key: String, values: [String]) {
        switch error as? CoreError {
        case .refused(let refusal): refusalMessage(refusal)
        case .offline: ("studio.error.offline", [])
        case .signInRequired: ("studio.error.signIn", [])
        case .forbidden: ("studio.error.forbidden", [])
        case .http(let status) where status == 402 || status == 429: ("studio.content.limit", [])
        default: ("studio.error.generic", [])
        }
    }

    static func refusalMessage(_ refusal: Refusal) -> (key: String, values: [String]) {
        switch refusal.code {
        case Refusal.uploadsByInvitation: ("studio.refusal.invitation", [])
        case Refusal.channelLimit: ("studio.refusal.channelLimit", [])
        case Refusal.uploadLimit: ("studio.upload.error.limit", [])
        case Refusal.upgradeRequired: refusal.message.map { (plainKey, [$0]) } ?? ("studio.content.limit", [])
        case Refusal.accountPendingDeletion: ("studio.account.pendingDeletion", [])
        case Refusal.banned: ("studio.account.banned", [])
        default: ("studio.error.generic", [])
        }
    }

    /// The refusal that applies to the whole account, if this error is one.
    static func accountState(_ error: any Error) -> Refusal? {
        if case .refused(let refusal) = error as? CoreError, refusal.isAccountState { return refusal }
        return nil
    }
}

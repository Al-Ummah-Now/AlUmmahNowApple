import Foundation

/// Account deletion for UI tests, snapshots and previews (`-AUNFixtureDeleteMode`).
public struct FixtureDeletionService: DeletionServicing {
    public enum Mode: String, Sendable {
        case succeed
        /// A channel that can't be read, another record, or both, stay behind.
        case unreadable, otherErrors, bothErrors
        /// No answer to the erase.
        case offline
        /// Many passes, each taking a while.
        case slow
        /// Auth refuses after the erase.
        case partial
        /// No answer to `DELETE /account`, nor to what became of it.
        case lost
        /// 503 with a `Retry-After` of five minutes, during the erase.
        case wait
    }

    let mode: Mode

    public init(mode: Mode = .succeed) { self.mode = mode }

    public func erase(accountID: String, token: String, resumeToken: String?) async throws -> DeletionAnswer {
        switch mode {
        case .offline: throw CoreError.offline
        case .slow:
            try await Task.sleep(for: .seconds(8))
            return DeletionAnswer(200, json: #"{"complete":false,"resumeToken":"next"}"#)
        case .wait:
            return DeletionAnswer(503, json: #"{"code":"resume_unavailable"}"#, retryAfter: "300")
        case .unreadable: return DeletionAnswer(200, json: #"{"complete":true,"errors":["channel_unreadable:c"]}"#)
        case .otherErrors: return DeletionAnswer(200, json: #"{"complete":true,"errors":["search"]}"#)
        case .bothErrors:
            return DeletionAnswer(200, json: #"{"complete":true,"errors":["channel_unreadable:c","search"]}"#)
        case .succeed, .partial, .lost: return DeletionAnswer(200, json: #"{"complete":true,"errors":[]}"#)
        }
    }

    public func deleteAccount(token: String) async throws -> DeletionAnswer {
        switch mode {
        case .partial: return DeletionAnswer(403, json: #"{"error":"forbidden"}"#)
        case .lost: throw CoreError.offline
        default: return DeletionAnswer(200, json: #"{"deleted":true}"#)
        }
    }

    public func deletionReceipt(token: String) async throws -> DeletionAnswer {
        DeletionAnswer(200, json: #"{"receipt":"fixture-receipt","expiresAt":4102444800000}"#)
    }

    public func accountStatus(receipt: String) async throws -> DeletionAnswer {
        if mode == .lost { throw CoreError.offline }
        return DeletionAnswer(200, json: #"{"deleted":false}"#)
    }

    public func serverNow() async -> Date? { nil }
}

/// No deletion in this build: every call fails, so nothing is ever taken for done.
struct UnavailableDeletionService: DeletionServicing {
    func erase(accountID: String, token: String, resumeToken: String?) async throws -> DeletionAnswer {
        throw CoreError.notFound
    }
    func deleteAccount(token: String) async throws -> DeletionAnswer { throw CoreError.notFound }
    func deletionReceipt(token: String) async throws -> DeletionAnswer { throw CoreError.notFound }
    func accountStatus(receipt: String) async throws -> DeletionAnswer { throw CoreError.notFound }
    func serverNow() async -> Date? { nil }
}

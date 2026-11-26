import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

let creator = FixtureAccountService.creator

/// Counts calls and answers what the test says; `pause` holds an erase until it is let go.
final class SpyDeletion: DeletionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _accountAnswers: [DeletionAnswer?]
    private var _states: [DeletionAnswer?]
    private var _onErase: (@Sendable () async -> Void)?
    private let erases: [DeletionAnswer?]
    private var eraseIndex = 0

    init(
        erases: [DeletionAnswer?] = [DeletionAnswer(200, json: #"{"complete":true,"errors":[]}"#)],
        account: [DeletionAnswer?] = [DeletionAnswer(200, json: #"{"deleted":true}"#)],
        states: [DeletionAnswer?] = [nil], onErase: (@Sendable () async -> Void)? = nil
    ) {
        self.erases = erases
        _accountAnswers = account
        _states = states
        _onErase = onErase
    }

    var calls: [String] { lock.withLock { _calls } }
    func onErase(_ action: @escaping @Sendable () async -> Void) { lock.withLock { _onErase = action } }
    func setStates(_ states: [DeletionAnswer?]) { lock.withLock { _states = states } }

    static func state(deleted: Bool) -> DeletionAnswer { DeletionAnswer(200, json: "{\"deleted\":\(deleted)}") }

    private func log(_ call: String) { lock.withLock { _calls.append(call) } }
    private func unwrap(_ answer: DeletionAnswer?) throws -> DeletionAnswer {
        guard let answer else { throw CoreError.offline }
        return answer
    }

    func erase(accountID: String, token: String, resumeToken: String?) async throws -> DeletionAnswer {
        log("erase")
        await lock.withLock { _onErase }?()
        let answer = lock.withLock { () -> DeletionAnswer? in
            defer { eraseIndex += 1 }
            return erases[min(eraseIndex, erases.count - 1)]
        }
        return try unwrap(answer)
    }
    func deleteAccount(token: String) async throws -> DeletionAnswer {
        log("delete")
        return try unwrap(lock.withLock { _accountAnswers.count > 1 ? _accountAnswers.removeFirst() : _accountAnswers[0] })
    }
    func deletionReceipt(token: String) async throws -> DeletionAnswer {
        DeletionAnswer(200, json: #"{"receipt":"r"}"#)
    }
    func accountStatus(receipt: String) async throws -> DeletionAnswer {
        log("status")
        return try unwrap(lock.withLock { _states.count > 1 ? _states.removeFirst() : _states[0] })
    }
    func serverNow() async -> Date? { nil }
}

@MainActor
struct DeleteAccountRig {
    let session: StudioSession
    let spy: SpyDeletion
    let records: MemoryDeletionRecords
    let accounts: FixtureAccountService
    let defaults: UserDefaults

    init(
        _ spy: SpyDeletion = SpyDeletion(), accounts: FixtureAccountService = FixtureAccountService(signedIn: [creator]),
        records: MemoryDeletionRecords = MemoryDeletionRecords(), authenticator: (any WebAuthenticating)? = nil,
        transfer: (any TUSTransferring)? = nil
    ) async {
        var services = StudioServices.fixtures(signedIn: true)
        services.accounts = accounts
        services.deletion = spy
        services.deletionRecords = records
        if let transfer { services.transfer = transfer }
        self.spy = spy
        self.records = records
        self.accounts = accounts
        defaults = UserDefaults(suiteName: "delete-account-\(UUID().uuidString)")!
        session = StudioSession(
            services: services, authenticator: authenticator ?? FixtureWebAuthenticator(), defaults: defaults)
        await session.start()
    }
}

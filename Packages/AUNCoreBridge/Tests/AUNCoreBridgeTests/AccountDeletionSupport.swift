import Foundation
import Testing

@testable import AUNCoreBridge

/// Every call of a deletion in order, across the services and the device.
final class DeletionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
    var erases: Int { all.count { $0.hasPrefix("erase") } }
    var deletes: Int { all.count { $0 == "delete" } }
}

/// Answers from a script, one per call; nil is an answer that never came. The last one repeats.
final class ScriptedService: DeletionServicing, @unchecked Sendable {
    let log: DeletionLog
    var erases: [DeletionAnswer?]
    var deletes: [DeletionAnswer?]
    var states: [DeletionAnswer?]
    var receipts: [DeletionAnswer?] = [DeletionAnswer(200, json: #"{"receipt":"r-new","expiresAt":4102444800000}"#)]
    private(set) var askedWith: [String] = []
    var clock: Date?
    private(set) var tokens: [String] = []

    init(
        _ log: DeletionLog, erases: [DeletionAnswer?] = [erased()], deletes: [DeletionAnswer?] = [accountGone],
        states: [DeletionAnswer?] = [accountState(deleted: false)]
    ) {
        self.log = log
        self.erases = erases
        self.deletes = deletes
        self.states = states
    }

    private func next(_ answers: inout [DeletionAnswer?]) throws -> DeletionAnswer {
        let answer = answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
        guard let answer else { throw URLError(.timedOut) }
        return answer
    }

    func erase(accountID: String, token: String, resumeToken: String?) async throws -> DeletionAnswer {
        log.add("erase:\(resumeToken ?? "-")")
        tokens.append(token)
        return try next(&erases)
    }
    func deleteAccount(token: String) async throws -> DeletionAnswer {
        log.add("delete")
        return try next(&deletes)
    }
    func deletionReceipt(token: String) async throws -> DeletionAnswer {
        log.add("receipt")
        return try next(&receipts)
    }
    func accountStatus(receipt: String) async throws -> DeletionAnswer {
        log.add("status")
        askedWith.append(receipt)
        return try next(&states)
    }
    func serverNow() async -> Date? { clock }
}

@MainActor final class FakeDeletionDevice: DeletionDevice {
    let log: DeletionLog
    var authTime = Date()
    var sessions: [DeletionSession] = []
    var tokenError: (any Error)?
    var holdError: (any Error)?
    var purgeError: (any Error)?
    var endError: (any Error)?
    var onHold: (() async -> Void)?
    private(set) var held = false
    private var issued = 0

    init(_ log: DeletionLog) { self.log = log }

    func session(of accountID: String) async throws -> DeletionSession {
        if let tokenError { throw tokenError }
        if !sessions.isEmpty { return sessions.removeFirst() }
        issued += 1
        return .token(DeletionToken.fixture(accountID: accountID, authTime: authTime) + "-\(issued)")
    }
    func holdUploads(of accountID: String) async throws {
        log.add("hold")
        if let holdError { throw holdError }
        held = true
        await onHold?()
    }
    func releaseUploads(of accountID: String) {
        log.add("release")
        held = false
    }
    func purgeUploads(of accountID: String) throws {
        log.add("purge")
        if let purgeError { throw purgeError }
    }
    func endSession(of accountID: String) async throws {
        log.add("end")
        if let endError { throw endError }
    }
    func forgetChoices(of accountID: String) { log.add("forget") }
}

func erased(_ errors: [String] = []) -> DeletionAnswer {
    let list = errors.map { "\"\($0)\"" }.joined(separator: ",")
    return DeletionAnswer(200, json: "{\"success\":true,\"complete\":true,\"errors\":[\(list)]}")
}

func eraseMore(_ token: String, errors: [String] = [], restarted: Bool = false) -> DeletionAnswer {
    let list = errors.map { "\"\($0)\"" }.joined(separator: ",")
    return DeletionAnswer(
        200, json: "{\"complete\":false,\"resumeToken\":\"\(token)\",\"restarted\":\(restarted),\"errors\":[\(list)]}")
}

let accountGone = DeletionAnswer(200, json: #"{"deleted":true,"userId":"u1"}"#)
let signInTooOld = DeletionAnswer(401, json: #"{"error":"insufficient_user_authentication","max_age":600}"#)
let tokenRevoked = DeletionAnswer(401, json: #"{"success":false,"error":"Unauthorized"}"#)

func accountState(deleted: Bool) -> DeletionAnswer {
    DeletionAnswer(200, json: "{\"deleted\":\(deleted)}")
}

@MainActor final class DeletionRig {
    let log = DeletionLog()
    let service: ScriptedService
    let device: FakeDeletionDevice
    let records: MemoryDeletionRecords
    let deletion: AccountDeletion

    init(_ record: DeletionRecord? = nil, now: Date = Date()) {
        service = ScriptedService(log)
        device = FakeDeletionDevice(log)
        records = MemoryDeletionRecords(record.map { [$0] } ?? [])
        deletion = AccountDeletion(records: records, service: service, device: device, now: { now })
    }

    var record: DeletionRecord? { (try? records.all())?.first }

    func run(
        accepting: Set<DeletionLeftover> = [], stopRequested: () -> Bool = { false },
        onPass: (Int, Bool) -> Void = { _, _ in }
    ) async -> DeletionOutcome {
        await deletion.run("u1", label: "u1@example.com", accepting: accepting, stopRequested: stopRequested, onPass: onPass)
    }
}

func deletionRecord(
    _ stage: DeletionStage, resumeToken: String? = nil, leftover: Set<DeletionLeftover> = [], notBefore: Date? = nil,
    receipt: String? = "r-old", expires: Date? = nil
) -> DeletionRecord {
    DeletionRecord(
        accountID: "u1", label: "u1@example.com", stage: stage, resumeToken: resumeToken, leftover: leftover,
        notBefore: notBefore, receipt: receipt,
        receiptExpires: expires)
}

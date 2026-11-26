import Foundation

/// What may be said about the content when a deletion stopped.
public enum ErasedSoFar: Hashable, Sendable {
    /// This attempt removed nothing, and none started before.
    case nothing
    /// Some content may be gone.
    case some
    /// The content is erased; the sign-in account is left.
    case content
}

public enum DeletionOutcome: Hashable, Sendable {
    /// The account is gone. `leftover`: what the person was told stays. `contentErased`: an erase over everything finished
    /// on this device (the account may have been deleted elsewhere before one did).
    case deleted(leftover: Set<DeletionLeftover>, contentErased: Bool)
    /// A recent sign-in of the same person is needed. Nothing more is removed until they confirm again.
    case needsSignIn(ErasedSoFar)
    /// The active account is not the one the person confirmed.
    case otherAccount(ErasedSoFar)
    /// The erase finished and left something: the person decides before the account goes.
    case leftBehind(Set<DeletionLeftover>)
    /// The server asked to wait.
    case wait(until: Date, ErasedSoFar)
    /// 50 passes, or the person stopped: they confirm again to go on.
    case paused(stopped: Bool, ErasedSoFar)
    /// It stopped on an error.
    case failed(ErasedSoFar)
    /// The answer to `DELETE /account` was lost: it may even be finished.
    case unknown
    /// The record could not be read or saved, so nothing more was called.
    case noRecord(ErasedSoFar)
}

/// The account's own token, as the device has it.
public enum DeletionSession: Sendable {
    case token(String)
    /// Another account is active.
    case otherAccount
    /// The account has no session here any more, or its refresh token was refused.
    case none
}

/// What the device keeps of an account, for the end of its deletion.
@MainActor public protocol DeletionDevice: AnyObject {
    /// Throws when the device could not say (offline during a refresh).
    func session(of accountID: String) async throws -> DeletionSession
    /// Holds the account's uploads until nothing of them is under way. Throws when that can't be reached.
    func holdUploads(of accountID: String) async throws
    func releaseUploads(of accountID: String)
    /// Removes queued and staged uploads, with a saved marker so a running one can't write back. Throws on failure.
    func purgeUploads(of accountID: String) throws
    /// Removes the session from this device. Works without the server: the account is gone there.
    func endSession(of accountID: String) async throws
    /// Removes what else is remembered for the account here.
    func forgetChoices(of accountID: String)
}

/// Deletes an account (App Store 5.1.1(v); wiki guides/data-lifecycle.md, the rules for every client) as one saved state
/// machine, `DeletionStage`:
///
///     confirmed → uploadsHeld → erasing ⟲ passes → contentErased → deleteSent → deleted → local clean-up → no record
///
/// The record is saved before each step and removed last, so a restart at any point knows what may have happened:
/// - before `erasing`, nothing was called: the record is dropped;
/// - `erasing`, `contentErased`: it is shown, and an attempt starts with the erase again (the account was live in between);
/// - `deleteSent`: Auth is asked what became of the account, before anything else;
/// - `deleted`: only this device's clean-up is left, and runs without the server.
@MainActor public final class AccountDeletion {
    /// The web app's privacy page uses the same limit; the server has none.
    public nonisolated static let maxPasses = 50
    /// The first pass starts with a margin inside Auth's 600 s, so the erase fits.
    public nonisolated static let firstMaxAge = 300
    /// Once a deletion has started: Auth's limit less 30 s, so a long erase is not stopped half-way.
    public nonisolated static let continueMaxAge = 570

    private let records: any DeletionRecordStoring
    private let service: any DeletionServicing
    private unowned let device: any DeletionDevice
    private let now: () -> Date
    /// Runs under way in this process: on the Mac each window has its own, on one set of records.
    private static var running: Set<Run> = []

    private struct Run: Hashable {
        let records: ObjectIdentifier
        let accountID: String
    }

    private func run(of accountID: String) -> Run { Run(records: ObjectIdentifier(records as AnyObject), accountID: accountID) }

    public init(
        records: any DeletionRecordStoring, service: any DeletionServicing, device: any DeletionDevice,
        now: @escaping () -> Date = Date.init
    ) {
        self.records = records
        self.service = service
        self.device = device
        self.now = now
    }

    /// One confirmed attempt for `accountID`. `accepting`: what the person was told stays and went on with.
    /// `stopRequested` is asked between requests; `onPass` is called after each pass that left more.
    public func run(
        _ accountID: String, label: String, accepting: Set<DeletionLeftover> = [],
        stopRequested: () -> Bool = { false }, onPass: (_ pass: Int, _ restarted: Bool) -> Void = { _, _ in }
    ) async -> DeletionOutcome {
        // Another window is at it, and may be anywhere between two calls.
        guard Self.running.insert(run(of: accountID)).inserted else { return .failed(.some) }
        defer { Self.running.remove(run(of: accountID)) }
        return await attempt(accountID, label, accepting, stopRequested, onPass)
    }

    /// Where a run starts from, or how it ends at once.
    private enum Step<Value> {
        case go(Value)
        case end(DeletionOutcome)
    }

    private func attempt(
        _ accountID: String, _ label: String, _ accepting: Set<DeletionLeftover>, _ stopRequested: () -> Bool,
        _ onPass: (Int, Bool) -> Void
    ) async -> DeletionOutcome {
        let saved: DeletionRecord?
        switch await earlier(accountID) {
        case .go(let record): saved = record
        case .end(let outcome): return outcome
        }
        let receipt: Receipt?
        switch await recentSignIn(accountID, saved) {
        case .go(let value): receipt = value
        case .end(let outcome): return outcome
        }
        var record = saved ?? DeletionRecord(accountID: accountID, label: label, stage: .confirmed)
        record.label = label
        // Saved before anything is called: it is all that can be asked with once the account is gone.
        if let receipt { (record.receipt, record.receiptExpires) = (receipt.value, receipt.expires) }
        record.notBefore = nil
        let before: ErasedSoFar = saved == nil ? .nothing : .some
        if !save(record) { return .noRecord(before) }
        let outcome = await held(record, before, accepting, stopRequested, onPass)
        switch outcome {
        // Held until it is known whether the account exists (an upload must not start for a deleted one).
        case .deleted, .unknown: break
        default: device.releaseUploads(of: accountID)
        }
        return outcome
    }

    /// The record of an earlier attempt, once it is settled what became of a lost answer.
    private func earlier(_ accountID: String) async -> Step<DeletionRecord?> {
        var saved: DeletionRecord?
        do {
            saved = try records.all().first { $0.accountID == accountID && $0.stage.started }
        } catch {
            AUNLog.studio.error("Deletion record unreadable: \(error)")
            return .end(.noRecord(.some))
        }
        if let record = saved, record.stage >= .deleteSent {
            switch await ask(record) {
            case .deleted: return .end(await finish(record))
            case .live:
                // The answer says this account exists: the request never arrived, or staff restored it.
                saved?.stage = .contentErased
                if let saved, !save(saved) { return .end(.noRecord(.some)) }
            case .unanswered: return .end(.unknown)
            case .refused: saved?.receipt = nil
            }
        }
        if let until = saved?.notBefore, until > now() { return .end(.wait(until: until, .some)) }
        return .go(saved)
    }

    /// The account's own token is of a recent sign-in: Auth's receipt for it.
    private func recentSignIn(_ accountID: String, _ saved: DeletionRecord?) async -> Step<Receipt?> {
        let before: ErasedSoFar = saved == nil ? .nothing : .some
        let token: String
        switch await pinned(accountID) {
        case .other: return .end(.otherAccount(before))
        case .noAnswer: return .end(.failed(before))
        case .none:
            if let saved, await ask(saved) == .deleted { return .end(await finish(saved)) }
            return .end(.needsSignIn(before))
        case .token(let value): token = value
        }
        let clock = await service.serverNow() ?? now()
        let maxAge = saved == nil ? Self.firstMaxAge : Self.continueMaxAge
        if DeletionToken.isRecent(token, now: clock, maxAge: maxAge) { return await receipt(token, accountID, saved, before) }
        // Deleted elsewhere since: signing in again could never work.
        if let saved, await ask(saved) == .deleted { return .end(await finish(saved)) }
        return .end(.needsSignIn(before))
    }

    private typealias Receipt = (value: String, expires: Date?)

    /// Asked for before the erase: a refusal or no answer stops it with nothing erased.
    ///
    /// Auth answers 404 `{"error":"not_found"}` here only for the account the verified token is for, and only when that
    /// account is deleted (status, or `deleted_at` set) or has no row any more (purged): it is gone, so nothing is erased.
    /// Any other 404 is an Auth without this route: the deletion goes on without a receipt.
    private func receipt(
        _ token: String, _ accountID: String, _ saved: DeletionRecord?, _ before: ErasedSoFar
    ) async -> Step<Receipt?> {
        guard let answer = try? await service.deletionReceipt(token: token) else { return .end(.failed(before)) }
        if let receipt = answer.receipt { return .go(receipt) }
        if answer.needsSignIn { return .end(.needsSignIn(before)) }
        if answer.saysNoAccount {
            return .end(await finish(saved ?? DeletionRecord(accountID: accountID, label: accountID, stage: .confirmed)))
        }
        switch answer.status {
        case 404: return .go(nil)
        case 401:
            // Refused for who is asking: deleted elsewhere since?
            if let saved, await ask(saved) == .deleted { return .end(await finish(saved)) }
            return .end(.needsSignIn(before))
        case 429:
            let until = now().addingTimeInterval(answer.retryAfterSeconds(now: now()))
            if var waiting = saved {
                waiting.notBefore = until
                _ = save(waiting)
            }
            return .end(.wait(until: until, before))
        default: return .end(.failed(before))
        }
    }

    /// An upload that went on would bring content back after the erase: without the hold, nothing is called.
    private func held(
        _ start: DeletionRecord, _ before: ErasedSoFar, _ accepting: Set<DeletionLeftover>, _ stopRequested: () -> Bool,
        _ onPass: (Int, Bool) -> Void
    ) async -> DeletionOutcome {
        var record = start
        do {
            try await device.holdUploads(of: record.accountID)
        } catch {
            AUNLog.studio.error("Uploads not held, so no deletion: \(error)")
            return .failed(drop(record))
        }
        if !record.stage.started {
            record.stage = .uploadsHeld
            if !save(record) { return .noRecord(before) }
        }
        if stopRequested() { return .paused(stopped: true, drop(record)) }
        return await erase(record, accepting, stopRequested, onPass)
    }

    // MARK: Restart

    /// What a start of the app found, for one record.
    public enum Settled: Hashable, Sendable {
        /// The account is gone: Auth says so now, so it may be shown.
        case deleted(DeletionRecord)
        /// The account was deleted earlier and this device's clean-up ran; Auth could not be asked again.
        case cleaned(DeletionRecord)
        /// Not finished: the person confirms again to finish.
        case open(DeletionRecord)
        /// `DELETE /account` was sent and Auth could not be asked what became of it.
        case unknown(DeletionRecord)
    }

    /// Picks up every record at a start: drops those that called nothing, finishes the clean-up of those that are done, and
    /// asks Auth about the rest. Safe to call any number of times.
    public func settle() async throws -> [Settled] {
        var settled: [Settled] = []
        for var record in try records.all() where !Self.running.contains(run(of: record.accountID)) {
            guard record.stage.started else {
                try? records.remove(record.accountID)
                continue
            }
            let state = await ask(record)
            if record.stage == .deleted {
                // Restored by staff before this device cleaned up: the deletion belongs to the past.
                if state == .live {
                    try? records.remove(record.accountID)
                } else {
                    await cleanUp(record.accountID)
                    settled.append(state == .deleted ? .deleted(record) : .cleaned(record))
                }
                continue
            }
            switch state {
            case .deleted:
                _ = await finish(record)
                settled.append(.deleted(record))
            case .live where record.stage == .deleteSent:
                record.stage = .contentErased
                _ = save(record)
                settled.append(.open(record))
            case .unanswered where record.stage == .deleteSent: settled.append(.unknown(record))
            // Refused: no receipt is left to ask with, so waiting for an answer holds nothing up any more.
            case .live, .refused, .unanswered: settled.append(.open(record))
            }
        }
        return settled
    }

    // MARK: Erase

    /// One run of the erase, pass by pass.
    private struct Erase {
        let start: DeletionRecord
        var record: DeletionRecord
        /// Some pass, of this attempt or an earlier one, removed something.
        var startedBefore: Bool
        /// Taken up from an earlier attempt: that run skips what the earlier one had finished, and content may have been
        /// added since. After it, one more from the start, which is quick when there is nothing left.
        var takenUp: Bool

        init(_ start: DeletionRecord) {
            self.start = start
            record = start
            startedBefore = start.stage.started
            takenUp = start.resumeToken != nil
            if !takenUp { record.leftover = [] }
            // What an earlier attempt had finished is not finished any more while this one runs.
            if record.stage > .erasing { record.stage = .erasing }
        }

        var erased: ErasedSoFar { startedBefore ? .some : .nothing }
    }

    private func erase(
        _ start: DeletionRecord, _ accepting: Set<DeletionLeftover>, _ stopRequested: () -> Bool,
        _ onPass: (Int, Bool) -> Void
    ) async -> DeletionOutcome {
        var run = Erase(start)
        for number in 1...Self.maxPasses {
            if number > 1 && stopRequested() { return .paused(stopped: true, run.erased) }
            switch await pass(&run) {
            case .end(let outcome): return outcome
            case .go(let restarted):
                if run.record.stage == .contentErased { return await afterErase(run.record, accepting) }
                onPass(number, restarted)
            }
        }
        return .paused(stopped: false, run.erased)
    }

    /// One pass. Goes on with whether the server began again.
    private func pass(_ run: inout Erase) async -> Step<Bool> {
        let token: String
        switch await pinned(run.record.accountID) {
        case .other: return .end(.otherAccount(nothingMore(run)))
        case .noAnswer: return .end(.failed(nothingMore(run)))
        case .none: return .end(await signInOrGone(run.record, nothingMore(run)))
        case .token(let value): token = value
        }
        if !run.record.stage.started { run.record.stage = .erasing }
        if !save(run.record) { return .end(.noRecord(run.erased)) }

        let answer: DeletionAnswer
        do {
            answer = try await service.erase(
                accountID: run.record.accountID, token: token, resumeToken: run.record.resumeToken)
        } catch {
            AUNLog.studio.error("Erase pass unanswered: \(error)")
            return .end(.failed(.some))
        }
        if let refused = await refusal(answer, run) { return .end(refused) }
        run.startedBefore = true
        guard let reply = try? JSONDecoder().decode(EraseReply.self, from: answer.body) else { return .end(.failed(.some)) }
        let complete = reply.complete == true
        let next = reply.resumeToken.flatMap { $0.isEmpty ? nil : $0 }
        if !complete && next == nil { return .end(.failed(.some)) }
        // A run that began again reports again what it cannot remove; any other goes on where the last pass ended.
        run.record.leftover = reply.leftover.union(reply.restarted == true ? [] : run.record.leftover)
        run.record.resumeToken = complete ? nil : next
        run.record.notBefore = nil
        if complete && run.takenUp {
            run.takenUp = false
            run.record.leftover = []
        } else if complete {
            run.record.stage = .contentErased
        }
        // The earlier record still says "erasing": the next attempt repeats this pass.
        return save(run.record) ? .go(reply.restarted == true) : .end(.noRecord(.some))
    }

    /// What an answer that removed nothing, or nothing that is known, means; nil for a pass that worked.
    private func refusal(_ answer: DeletionAnswer, _ run: Erase) async -> DeletionOutcome? {
        switch answer.status {
        case 200..<300: return nil
        case 429: return wait(answer, run.record, nothingMore(run))
        case 503: return wait(answer, run.record, .some)
        case 401:
            if answer.needsSignIn { return .needsSignIn(nothingMore(run)) }
            return await signInOrGone(run.record, nothingMore(run))
        // Refused before the erase began.
        case 400, 403, 404: return .failed(nothingMore(run))
        default: return .failed(.some)
        }
    }

    /// This pass removed nothing: a record made for it would say otherwise, unless something went before.
    private func nothingMore(_ run: Erase) -> ErasedSoFar { run.startedBefore ? .some : drop(run.start) }

    private func wait(_ answer: DeletionAnswer, _ record: DeletionRecord, _ so: ErasedSoFar) -> DeletionOutcome {
        let until = now().addingTimeInterval(answer.retryAfterSeconds(now: now()))
        if so != .nothing {
            var waiting = record
            waiting.notBefore = until
            _ = save(waiting)
        }
        return .wait(until: until, so)
    }

    // MARK: Account

    private func afterErase(_ record: DeletionRecord, _ accepting: Set<DeletionLeftover>) async -> DeletionOutcome {
        // Never more than what they were told about.
        guard record.leftover.isSubset(of: accepting) else { return .leftBehind(record.leftover) }
        let content: ErasedSoFar = record.leftover.isEmpty ? .content : .some
        var record = record
        var lost = false
        for _ in 0..<2 {
            let token: String
            switch await pinned(record.accountID) {
            case .other: return lost ? await settleLost(record, content) : .otherAccount(content)
            case .noAnswer: return lost ? await settleLost(record, content) : .failed(content)
            case .none: return lost ? await settleLost(record, content) : await signInOrGone(record, content)
            case .token(let value): token = value
            }
            record.stage = .deleteSent
            if !save(record) { return lost ? .unknown : .noRecord(content) }
            let answer = try? await service.deleteAccount(token: token)
            if let answer, answer.saysDeleted { return await finish(record) }
            guard let answer, answer.status < 500, !(200..<300).contains(answer.status) else {
                // Auth may have committed although its answer was lost or says otherwise: ask again, once.
                lost = true
                continue
            }
            if lost { return await settleLost(record, content) }
            // Refused: the account is as it was.
            record.stage = .contentErased
            _ = save(record)
            if answer.needsSignIn { return .needsSignIn(content) }
            return answer.status == 401 ? await signInOrGone(record, content) : .failed(content)
        }
        return await settleLost(record, content)
    }

    /// Two answers were lost, or the second says something else than the first may have done: ask what became of it.
    private func settleLost(_ record: DeletionRecord, _ content: ErasedSoFar) async -> DeletionOutcome {
        switch await ask(record) {
        case .deleted: return await finish(record)
        case .live:
            var open = record
            open.stage = .contentErased
            _ = save(open)
            return .failed(content)
        case .refused, .unanswered: return .unknown
        }
    }

    /// Refused for who is asking: the account may have been deleted elsewhere. Then a sign-in could never work.
    private func signInOrGone(_ record: DeletionRecord, _ so: ErasedSoFar) async -> DeletionOutcome {
        await ask(record) == .deleted ? await finish(record) : .needsSignIn(so)
    }

    private enum AccountState { case deleted, live, unanswered, refused }

    /// Asks with the record's receipt. One that expired, or that Auth refuses, is dropped: nothing is asked with it again.
    private func ask(_ record: DeletionRecord) async -> AccountState {
        guard let receipt = record.receipt else { return .refused }
        if let expires = record.receiptExpires, expires <= now() {
            forgetReceipt(record)
            return .refused
        }
        guard let answer = try? await service.accountStatus(receipt: receipt) else { return .unanswered }
        if answer.status == 401 {
            forgetReceipt(record)
            return .refused
        }
        guard answer.status == 200, let deleted = answer.deleted else { return .unanswered }
        return deleted ? .deleted : .live
    }

    private func forgetReceipt(_ record: DeletionRecord) {
        // Only where it is saved: a record that was dropped meanwhile must not come back.
        guard var saved = try? records.all().first(where: { $0.accountID == record.accountID }),
            saved.receipt == record.receipt
        else { return }
        (saved.receipt, saved.receiptExpires) = (nil, nil)
        _ = save(saved)
    }

    // MARK: Clean-up

    private func finish(_ record: DeletionRecord) async -> DeletionOutcome {
        AUNLog.studio.info("Account deleted")
        var done = record
        done.stage = .deleted
        done.resumeToken = nil
        _ = save(done)
        await cleanUp(record.accountID)
        return .deleted(leftover: record.leftover, contentErased: record.stage >= .contentErased)
    }

    /// Uploads, session, record, in that order. What fails is finished at the next start; it is never an error here.
    private func cleanUp(_ accountID: String) async {
        var clean = true
        do {
            try device.purgeUploads(of: accountID)
        } catch {
            AUNLog.studio.error("Uploads of a deleted account are left for the next start: \(error)")
            clean = false
        }
        // The session must not outlive its account, also when the uploads could not be removed.
        do {
            try await device.endSession(of: accountID)
        } catch {
            AUNLog.studio.error("Session of a deleted account is left for the next start: \(error)")
            clean = false
        }
        guard clean else { return }
        device.forgetChoices(of: accountID)
        do {
            try records.remove(accountID)
        } catch {
            AUNLog.studio.error("Record of a finished deletion is left for the next start: \(error)")
        }
    }

    // MARK: Helpers

    private enum Pinned {
        case token(String)
        case other
        case none
        case noAnswer
    }

    /// The account's own token, checked by its `properties.id` before every call (a refresh may have replaced it).
    private func pinned(_ accountID: String) async -> Pinned {
        do {
            switch try await device.session(of: accountID) {
            case .token(let token): return DeletionToken.accountID(of: token) == accountID ? .token(token) : .other
            case .otherAccount: return .other
            case .none: return .none
            }
        } catch {
            AUNLog.studio.error("No token for the deletion: \(error)")
            return .noAnswer
        }
    }

    private func save(_ record: DeletionRecord) -> Bool {
        do {
            try records.save(record)
            return true
        } catch {
            AUNLog.studio.error("Deletion record not saved: \(error)")
            return false
        }
    }

    /// Takes back a record for which nothing was removed. One that can't be removed stays, and says so.
    private func drop(_ record: DeletionRecord) -> ErasedSoFar {
        if record.stage.started { return .some }
        do {
            try records.remove(record.accountID)
            return .nothing
        } catch {
            return .some
        }
    }
}

private struct EraseReply: Decodable {
    let complete: Bool?
    let resumeToken: String?
    let restarted: Bool?
    let errors: [String]?

    /// Each kind that is there: one never hides the other.
    var leftover: Set<DeletionLeftover> {
        Set((errors ?? []).map { $0.hasPrefix("channel_unreadable:") ? .channel : .other })
    }
}

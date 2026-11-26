import Foundation
import Testing

@testable import AUNCoreBridge

@MainActor @Suite struct AccountDeletionTests {
    // MARK: The whole run

    @Test func runsEveryStepInOrderAndLeavesNoRecord() async {
        let rig = DeletionRig()
        rig.service.erases = [eraseMore("t1"), erased()]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
        #expect(rig.log.all == ["receipt", "hold", "erase:-", "erase:t1", "delete", "purge", "end", "forget"])
        #expect(rig.record == nil)
    }

    @Test func everyPassHasItsOwnFreshToken() async {
        let rig = DeletionRig()
        rig.service.erases = [eraseMore("t1"), eraseMore("t2"), erased()]
        _ = await rig.run()
        #expect(Set(rig.service.tokens).count == 3)
    }

    @Test func theRecordIsSavedBeforeTheCallItIsFor() async {
        final class Spy: DeletionRecordStoring, @unchecked Sendable {
            let log: DeletionLog
            let base = MemoryDeletionRecords()
            init(_ log: DeletionLog) { self.log = log }
            func all() throws -> [DeletionRecord] { try base.all() }
            func save(_ record: DeletionRecord) throws {
                log.add("save:\(record.stage.rawValue)")
                try base.save(record)
            }
            func remove(_ accountID: String) throws { try base.remove(accountID) }
        }
        let rig = DeletionRig()
        let spy = Spy(rig.log)
        let deletion = AccountDeletion(records: spy, service: rig.service, device: rig.device)
        _ = await deletion.run("u1", label: "u1")
        #expect(
            rig.log.all == [
                "receipt", "save:confirmed", "hold", "save:uploadsHeld", "save:erasing", "erase:-", "save:contentErased",
                "save:deleteSent", "delete", "save:deleted", "purge", "end", "forget",
            ])
    }

    // MARK: Before anything is called

    @Test func anOldSignInCallsNothingAndLeavesNoRecord() async {
        let rig = DeletionRig()
        rig.device.authTime = Date(timeIntervalSinceNow: -301)
        #expect(await rig.run() == .needsSignIn(.nothing))
        #expect(rig.log.all.isEmpty)
        #expect(rig.record == nil)
    }

    @Test func recencyIsMeasuredOnTheServersClock() async {
        let rig = DeletionRig()
        rig.service.clock = Date(timeIntervalSinceNow: 3600)
        #expect(await rig.run() == .needsSignIn(.nothing))
        #expect(rig.log.erases == 0)
    }

    @Test func aStartedDeletionMayGoOnWithALongerSignIn() async {
        let rig = DeletionRig(deletionRecord(.erasing))
        rig.device.authTime = Date(timeIntervalSinceNow: -500)
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
    }

    @Test func anotherAccountsTokenIsNeverUsed() async {
        let rig = DeletionRig()
        rig.device.sessions = [.token(DeletionToken.fixture(accountID: "u2", authTime: Date()))]
        #expect(await rig.run() == .otherAccount(.nothing))
        rig.device.sessions = [.otherAccount]
        #expect(await rig.run() == .otherAccount(.nothing))
        #expect(rig.log.all.isEmpty)
        #expect(rig.record == nil)
    }

    @Test func theSubjectIsNeverTakenForTheAccount() {
        let payload = Data(#"{"sub":"u1","auth_time":1}"#.utf8).base64EncodedString()
        #expect(DeletionToken.accountID(of: "e30.\(payload).x") == nil)
        #expect(DeletionToken.accountID(of: "not a token") == nil)
    }

    @Test func uploadsThatCantBeHeldMeanNothingIsCalled() async {
        let rig = DeletionRig()
        rig.device.holdError = URLError(.timedOut)
        #expect(await rig.run() == .failed(.nothing))
        #expect(rig.log.all == ["receipt", "hold", "release"])
        #expect(rig.record == nil)
    }

    @Test func aRecordThatCantBeReadOrSavedMeansNothingIsCalled() async {
        let rig = DeletionRig()
        rig.records.fail(true)
        #expect(await rig.run() == .noRecord(.some))
        #expect(rig.log.all.isEmpty)
    }

    @Test func stoppingWhileUploadsAreHeldRemovesNothing() async {
        let rig = DeletionRig()
        #expect(await rig.run(stopRequested: { true }) == .paused(stopped: true, .nothing))
        #expect(rig.log.all == ["receipt", "hold", "release"])
        #expect(rig.record == nil)
    }

    // MARK: Passes

    @Test(arguments: [400, 401, 403, 404]) func aRefusedFirstPassLeavesNoRecord(_ status: Int) async {
        let rig = DeletionRig()
        rig.service.erases = [DeletionAnswer(status, json: #"{"error":"x"}"#)]
        let outcome = await rig.run()
        #expect(outcome == (status == 401 ? .needsSignIn(.nothing) : .failed(.nothing)))
        #expect(rig.record == nil)
        #expect(rig.log.deletes == 0)
        #expect(!rig.device.held)
    }

    @Test func aRefusalLaterSaysContentMayBeGone() async {
        let rig = DeletionRig()
        rig.service.erases = [eraseMore("t1"), signInTooOld]
        #expect(await rig.run() == .needsSignIn(.some))
        #expect(rig.record?.stage == .erasing)
        #expect(rig.record?.resumeToken == "t1")
    }

    @Test func noAnswerToAnEraseSaysContentMayBeGone() async {
        let rig = DeletionRig()
        rig.service.erases = [nil]
        #expect(await rig.run() == .failed(.some))
        #expect(rig.record?.stage == .erasing)
        #expect(rig.log.deletes == 0)
    }

    @Test func incompleteWithoutATokenIsNotFinished() async {
        let rig = DeletionRig()
        rig.service.erases = [DeletionAnswer(200, json: #"{"complete":false}"#)]
        #expect(await rig.run() == .failed(.some))
        #expect(rig.log.deletes == 0)
    }

    @Test func anUnreadableAnswerIsNotFinished() async {
        let rig = DeletionRig()
        rig.service.erases = [DeletionAnswer(200, json: "<html>")]
        #expect(await rig.run() == .failed(.some))
        #expect(rig.log.deletes == 0)
    }

    @Test func errorsOfEarlierPassesAreKeptAcrossPasses() async {
        let rig = DeletionRig()
        rig.service.erases = [eraseMore("t1", errors: ["channel_unreadable:c9"]), eraseMore("t2", errors: ["search"]), erased()]
        #expect(await rig.run() == .leftBehind([.channel, .other]))
        #expect(rig.log.deletes == 0)
    }

    @Test func errorsAreSavedWithTheTokenAndSurviveARestart() async {
        let rig = DeletionRig()
        rig.service.erases = [eraseMore("t1", errors: ["channel_unreadable:c9"]), nil]
        #expect(await rig.run() == .failed(.some))
        #expect(rig.record?.leftover == [.channel])
        #expect(rig.record?.resumeToken == "t1")
    }

    @Test func aRunThatBeganAgainReportsItsOwnErrors() async {
        let rig = DeletionRig()
        rig.service.erases = [eraseMore("t1", errors: ["channel_unreadable:c9"]), eraseMore("t2", restarted: true), erased()]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
    }

    @Test func onlyWhatThePersonWasToldIsAccepted() async {
        let rig = DeletionRig()
        rig.service.erases = [erased(["channel_unreadable:c9"])]
        #expect(await rig.run() == .leftBehind([.channel]))
        rig.service.erases = [erased(["channel_unreadable:c9", "search"])]
        #expect(await rig.run(accepting: [.channel]) == .leftBehind([.channel, .other]))
        #expect(rig.log.deletes == 0)
        #expect(await rig.run(accepting: [.channel, .other]) == .deleted(leftover: [.channel, .other], contentErased: true))
    }

    @Test func aRunTakenUpFromAnEarlierAttemptIsFollowedByOneFromTheStart() async {
        let rig = DeletionRig(deletionRecord(.erasing, resumeToken: "t1", leftover: [.channel]))
        rig.service.erases = [erased(), erased(["channel_unreadable:c9"])]
        #expect(await rig.run() == .leftBehind([.channel]))
        #expect(rig.log.all.filter { $0.hasPrefix("erase") } == ["erase:t1", "erase:-"])
        // Nothing left to add: the second one is the proof for Auth.
        rig.service.erases = [erased()]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
    }

    @Test func everyAttemptErasesAgainBeforeTheAccountGoes() async {
        let rig = DeletionRig()
        rig.service.deletes = [DeletionAnswer(403, json: #"{"error":"forbidden"}"#), accountGone]
        #expect(await rig.run() == .failed(.content))
        #expect(rig.record?.stage == .contentErased)
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
        #expect(rig.log.erases == 2)
    }

    @Test func fiftyPassesThenThePersonConfirmsAgain() async {
        let rig = DeletionRig()
        rig.service.erases = [eraseMore("t")]
        #expect(await rig.run() == .paused(stopped: false, .some))
        #expect(rig.log.erases == 50)
        #expect(rig.record?.resumeToken == "t")
        #expect(!rig.device.held)
    }

    @Test func stopEndsTheRunBetweenPasses() async {
        let rig = DeletionRig()
        rig.service.erases = [eraseMore("t")]
        var passes = 0
        let outcome = await rig.run(stopRequested: { passes >= 2 }, onPass: { pass, _ in passes = pass })
        #expect(outcome == .paused(stopped: true, .some))
        #expect(rig.log.erases == 2)
        #expect(rig.log.deletes == 0)
    }

    // MARK: Waiting

    @Test func retryAfterIsHonoured() async {
        let now = Date()
        let rig = DeletionRig(now: now)
        rig.service.erases = [DeletionAnswer(503, json: #"{"code":"resume_unavailable"}"#, retryAfter: "300")]
        #expect(await rig.run() == .wait(until: now.addingTimeInterval(300), .some))
        #expect(rig.record?.notBefore == now.addingTimeInterval(300))
        // Asked again too early: nothing is called.
        #expect(await rig.run() == .wait(until: now.addingTimeInterval(300), .some))
        #expect(rig.log.erases == 1)
    }

    @Test func tooManyRequestsRemovedNothing() async {
        let now = Date()
        let rig = DeletionRig(now: now)
        rig.service.erases = [DeletionAnswer(429, json: "{}", retryAfter: "60")]
        #expect(await rig.run() == .wait(until: now.addingTimeInterval(60), .nothing))
        #expect(rig.record == nil)
    }

    @Test func retryAfterReadsSecondsAndDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(DeletionAnswer(status: 503, retryAfter: "300").retryAfterSeconds(now: now) == 300)
        #expect(DeletionAnswer(status: 503, retryAfter: "7200").retryAfterSeconds(now: now) == 7200)
        #expect(DeletionAnswer(status: 503, retryAfter: "Fri, 15 Jan 2027 08:10:00 GMT").retryAfterSeconds(now: now) == 600)
        for header in [nil, "", "soon", "0", "-5", "1e3"] {
            #expect(DeletionAnswer(status: 503, retryAfter: header).retryAfterSeconds(now: now) == 300)
        }
    }

    // MARK: The account

    @Test(arguments: ["{}", #"{"deleted":false}"#, "<html>"]) func onlyDeletedTrueIsDeleted(_ body: String) async {
        let rig = DeletionRig()
        rig.service.deletes = [DeletionAnswer(200, json: body)]
        #expect(await rig.run() == .failed(.content))
        #expect(rig.record?.stage == .contentErased)
    }

    @Test func notFoundAfterTheEraseIsGoneAndOther404sAreNot() async {
        let rig = DeletionRig()
        rig.service.deletes = [DeletionAnswer(404, json: #"{"error":"route"}"#)]
        #expect(await rig.run() == .failed(.content))
        rig.service.deletes = [DeletionAnswer(404, json: #"{"error":"not_found"}"#)]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
    }

    @Test func aSignInTooOldForAuthSaysTheContentIsGoneAndTheNextAttemptErasesAgain() async {
        let rig = DeletionRig()
        rig.service.deletes = [signInTooOld, accountGone]
        #expect(await rig.run() == .needsSignIn(.content))
        #expect(rig.record?.stage == .contentErased)
        #expect(!rig.device.held)
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
        #expect(rig.log.erases == 2)
    }

    // MARK: A lost answer

    @Test func aLostAnswerIsAskedForAgain() async {
        let rig = DeletionRig()
        rig.service.deletes = [nil, accountGone]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
        #expect(rig.log.deletes == 2)
        #expect(rig.record == nil)
    }

    @Test func aServerErrorMayHaveDeletedToo() async {
        let rig = DeletionRig()
        rig.service.deletes = [DeletionAnswer(status: 502), accountGone]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
    }

    @Test func whenBothAnswersAreLostAuthSaysWhatBecameOfIt() async {
        let rig = DeletionRig()
        rig.service.deletes = [nil]
        rig.service.states = [accountState(deleted: true)]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
        let other = DeletionRig()
        other.service.deletes = [nil]
        #expect(await other.run() == .failed(.content))
        #expect(other.record?.stage == .contentErased)
    }

    @Test func aRefusalAfterALostAnswerIsNoProofThatItFailed() async {
        let rig = DeletionRig()
        rig.service.deletes = [nil, tokenRevoked]
        rig.service.states = [accountState(deleted: true)]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
    }

    @Test func noAnswerAtAllIsUnknownAndUploadsStayHeld() async {
        let rig = DeletionRig()
        rig.service.deletes = [nil]
        rig.service.states = [nil]
        #expect(await rig.run() == .unknown)
        #expect(rig.record?.stage == .deleteSent)
        #expect(rig.record?.receipt == "r-new")
        #expect(rig.device.held)
    }

    @Test func aRetryAfterALostAnswerAsksAuthBeforeTheEraseThatARevokedAccountIsRefused() async {
        let rig = DeletionRig(deletionRecord(.deleteSent))
        rig.service.states = [accountState(deleted: true)]
        rig.service.erases = [tokenRevoked]
        rig.device.sessions = [.none]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
        #expect(rig.log.erases == 0)
        #expect(rig.record == nil)
    }

    @Test func aRetryWhoseAccountIsAliveStartsWithTheErase() async {
        let rig = DeletionRig(deletionRecord(.deleteSent))
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
        #expect(rig.log.all.first == "status")
        #expect(rig.log.erases == 1)
        #expect(rig.log.deletes == 1)
    }

    @Test func anAccountDeletedElsewhereIsSettledWhereverItIsNoticed() async {
        // Its token is refused by the erase.
        let refused = DeletionRig()
        refused.service.erases = [eraseMore("t1"), tokenRevoked]
        refused.service.states = [accountState(deleted: true)]
        #expect(await refused.run() == .deleted(leftover: [], contentErased: false))
        // Its session is gone.
        let signedOut = DeletionRig(deletionRecord(.erasing))
        signedOut.device.sessions = [.none]
        signedOut.service.states = [accountState(deleted: true)]
        #expect(await signedOut.run() == .deleted(leftover: [], contentErased: false))
        // Its sign-in is too old, and a new one could never work.
        let old = DeletionRig(deletionRecord(.contentErased))
        old.device.authTime = Date(timeIntervalSinceNow: -5000)
        old.service.states = [accountState(deleted: true)]
        #expect(await old.run() == .deleted(leftover: [], contentErased: true))
    }

    @Test func anAnswerThatDoesNotSayDeletedProvesNothing() async {
        for answer in [DeletionAnswer(200, json: "{}"), DeletionAnswer(200, json: "<html>"), DeletionAnswer(429, json: "{}")] {
            let rig = DeletionRig(deletionRecord(.deleteSent))
            rig.service.states = [answer]
            #expect(await rig.run() == .unknown)
        }
    }
}

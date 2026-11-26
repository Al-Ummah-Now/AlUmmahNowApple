import Foundation
import Testing

@testable import AUNCoreBridge

/// The receipt Auth gives before the erase, and what it settles.
@MainActor @Suite struct AccountDeletionReceiptTests {
    @Test func theReceiptIsSavedBeforeAnythingIsCalledAndIsWhatAuthIsAskedWith() async {
        let rig = DeletionRig()
        rig.service.deletes = [nil]
        rig.service.states = [accountState(deleted: true)]
        rig.device.onHold = { #expect(rig.record?.receipt == "r-new") }
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
        #expect(rig.service.askedWith == ["r-new"])
    }

    @Test func eachAttemptHasItsOwnReceiptAndAnEarlierOneIsSettledWithItsOwn() async {
        let rig = DeletionRig(deletionRecord(.deleteSent))
        rig.service.deletes = [nil]
        rig.service.states = [accountState(deleted: false), accountState(deleted: true)]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
        #expect(rig.service.askedWith == ["r-old", "r-new"])
    }

    @Test func withoutAReceiptNothingIsCalled() async {
        let answers: [(DeletionAnswer?, DeletionOutcome)] = [
            (nil, .failed(.nothing)), (DeletionAnswer(503, json: "{}"), .failed(.nothing)),
            (DeletionAnswer(200, json: "{}"), .failed(.nothing)),
            (signInTooOld, .needsSignIn(.nothing)), (tokenRevoked, .needsSignIn(.nothing)),
        ]
        for (answer, outcome) in answers {
            let rig = DeletionRig()
            rig.service.receipts = [answer]
            #expect(await rig.run() == outcome)
            #expect(rig.log.all == ["receipt"])
            #expect(rig.record == nil)
        }
    }

    @Test func anAuthWithoutReceiptsIsAskedWithoutOne() async {
        let rig = DeletionRig()
        rig.service.receipts = [DeletionAnswer(404, json: "{}")]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
        let lost = DeletionRig()
        lost.service.receipts = [DeletionAnswer(404, json: "{}")]
        lost.service.deletes = [nil]
        #expect(await lost.run() == .unknown)
        #expect(lost.record?.receipt == nil)
    }

    @Test func anAccountDeletedElsewhereIsRefusedAReceiptAndSettledWithTheEarlierOne() async {
        let rig = DeletionRig(deletionRecord(.erasing))
        rig.service.receipts = [tokenRevoked]
        rig.service.states = [accountState(deleted: true)]
        #expect(await rig.run() == .deleted(leftover: [], contentErased: false))
        #expect(rig.log.erases == 0)
    }

    @Test func authsOwnNotFoundForTheReceiptIsAnAccountThatIsGoneSoNothingIsErased() async {
        for saved in [nil, deletionRecord(.erasing), deletionRecord(.contentErased)] {
            let rig = DeletionRig(saved)
            rig.service.receipts = [DeletionAnswer(404, json: #"{"error":"not_found","error_description":"Account not found"}"#)]
            #expect(await rig.run() == .deleted(leftover: [], contentErased: saved?.stage == .contentErased))
            #expect(rig.log.all == ["receipt", "purge", "end", "forget"])
            #expect(rig.record == nil)
        }
    }

    @Test func anyOther404ForTheReceiptIsAMissingRoute() async {
        for body in ["{}", "", "Not found", #"{"error":"route_not_found"}"#] {
            let rig = DeletionRig()
            rig.service.receipts = [DeletionAnswer(404, json: body)]
            _ = await rig.run()
            #expect(rig.log.erases == 1)
        }
    }

    @Test func anExpiredReceiptIsNotAskedWithAndADroppedOneNeverAgain() async {
        let expired = DeletionRig(deletionRecord(.deleteSent, expires: Date(timeIntervalSinceNow: -1)))
        expired.device.sessions = [.none]
        #expect(await expired.run() == .needsSignIn(.some))
        #expect(!expired.log.all.contains("status"))
        #expect(expired.record?.receipt == nil)
        #expect(expired.record?.unsettled == true)

        let refused = DeletionRig(deletionRecord(.deleteSent))
        refused.service.states = [DeletionAnswer(401, json: #"{"error":"receipt_invalid"}"#)]
        refused.device.sessions = [.none, .none]
        _ = await refused.run()
        _ = await refused.run()
        #expect(refused.log.all.count { $0 == "status" } == 1)
        #expect(refused.record?.unsettled == true)
    }

    @Test func whenTheReceiptExpiresIsSaved() async {
        let rig = DeletionRig()
        rig.service.receipts = [DeletionAnswer(200, json: #"{"receipt":"r","expiresAt":1800000000000}"#)]
        rig.service.erases = [nil]
        _ = await rig.run()
        #expect(rig.record?.receiptExpires == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func aWaitForTheReceiptIsKeptWithADeletionThatStarted() async {
        let now = Date()
        let rig = DeletionRig(deletionRecord(.erasing), now: now)
        rig.service.receipts = [DeletionAnswer(429, json: "{}", retryAfter: "60")]
        #expect(await rig.run() == .wait(until: now.addingTimeInterval(60), .some))
        #expect(rig.record?.notBefore == now.addingTimeInterval(60))
    }

    @Test func aLostAnswerIsSettledAlsoWhenTheSessionChangedMeanwhile() async {
        for session in [DeletionSession.otherAccount, .none] {
            let rig = DeletionRig()
            let token = DeletionToken.fixture(accountID: "u1", authTime: Date())
            rig.device.sessions = [.token(token), .token(token), .token(token), session]
            rig.service.deletes = [nil]
            rig.service.states = [accountState(deleted: true)]
            #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
            #expect(rig.log.deletes == 1)
        }
    }

    @Test func aReceiptThatExpiredLeavesItToTheSession() async {
        // A session that still works: the account exists.
        let live = DeletionRig(deletionRecord(.deleteSent))
        live.service.states = [DeletionAnswer(401, json: "{}")]
        #expect(await live.run() == .deleted(leftover: [], contentErased: true))
        #expect(live.log.erases == 1)
        let gone = DeletionRig(deletionRecord(.deleteSent))
        gone.service.states = [DeletionAnswer(401, json: "{}")]
        gone.device.sessions = [.none]
        #expect(await gone.run() == .needsSignIn(.some))
        #expect(gone.record?.stage == .deleteSent)
    }
}

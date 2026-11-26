import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

@MainActor
struct DeleteAccountTests {
    private struct CancellingAuthenticator: WebAuthenticating {
        func authenticate(_ request: SignInRequest) async throws -> URL { throw CoreError.cancelled }
    }

    /// Comes back with another sign-in's answer.
    private struct CrossedAuthenticator: WebAuthenticating {
        func authenticate(_ request: SignInRequest) async throws -> URL {
            URL(string: "\(request.callbackScheme)://auth/callback?code=x&state=someone-elses")!
        }
    }

    private func old() -> FixtureAccountService {
        FixtureAccountService(signedIn: [creator], signedInAt: Date(timeIntervalSinceNow: -3600))
    }

    private func record(_ stage: DeletionStage, leftover: Set<DeletionLeftover> = []) -> DeletionRecord {
        DeletionRecord(
            accountID: creator.id, label: "yusuf.rahman@example.org", stage: stage, leftover: leftover,
            receipt: "r")
    }

    // MARK: The dialog

    @Test func deletingRemovesTheAccountAndSaysSo() async throws {
        let rig = await DeleteAccountRig()
        let model = DeleteAccountModel(account: creator, session: rig.session)
        #expect(!model.canAct(typed: ""))
        #expect(model.canAct(typed: "DELETE"))
        await model.act()
        #expect(model.end == .deleted)
        #expect(rig.spy.calls == ["erase", "delete"])
        #expect(rig.session.phase == .signedOut)
        #expect(rig.session.accounts.isEmpty)
        #expect(rig.session.notice?.key == "studio.deleteAccount.done")
        #expect(rig.session.notice?.purgeDays == 30)
        #expect(rig.session.notice?.isError == false)
        #expect(try rig.records.all().isEmpty)
        #expect(!rig.session.isDeletingAccount)
    }

    @Test func theNextAccountIsShownAfterwards() async {
        let other = StudioAccount(id: "other", email: "amina.yusuf@example.org")
        let rig = await DeleteAccountRig(accounts: FixtureAccountService(signedIn: [creator, other]))
        await DeleteAccountModel(account: creator, session: rig.session).act()
        #expect(rig.session.account?.id == "other")
        #expect(rig.session.accounts.map(\.id) == ["other"])
        #expect(rig.session.notice?.key == "studio.deleteAccount.done")
    }

    @Test func aFreshSignInComesBeforeAnythingIsErasedAndOnlyLetsThemConfirmAgain() async throws {
        let rig = await DeleteAccountRig(accounts: old())
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        #expect(model.action == .signIn)
        #expect(model.message == "studio.deleteAccount.signIn")
        #expect(model.canAct(typed: ""))
        #expect(rig.spy.calls.isEmpty)
        #expect(await rig.accounts.stepUpCount == 0)
        await model.act()
        #expect(await rig.accounts.stepUpCount == 1)
        #expect(model.action == .delete)
        #expect(model.message == "studio.deleteAccount.signedInAgain")
        #expect(rig.spy.calls.isEmpty)
        #expect(try rig.records.all().isEmpty)
        await model.act()
        #expect(model.end == .deleted)
        #expect(rig.spy.calls == ["erase", "delete"])
    }

    @Test func cancellingTheSignInLeavesNoTrace() async throws {
        let rig = await DeleteAccountRig(accounts: old(), authenticator: CancellingAuthenticator())
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        await model.act()
        #expect(model.message == "studio.deleteAccount.signInFailed")
        #expect(rig.spy.calls.isEmpty)
        #expect(try rig.records.all().isEmpty)
        #expect(rig.session.openDeletions.isEmpty)
        #expect(rig.session.uploads.heldAccounts.isEmpty)
        #expect(rig.session.phase == .signedIn)
        // The next start says nothing either.
        let again = StudioSession(
            services: rig.session.services, authenticator: FixtureWebAuthenticator(), defaults: rig.defaults)
        await again.start()
        #expect(again.notice == nil)
        #expect(again.openDeletions.isEmpty)
    }

    @Test func anAnswerToAnotherSignInIsNotUsed() async throws {
        let rig = await DeleteAccountRig(accounts: old(), authenticator: CrossedAuthenticator())
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        await model.act()
        #expect(model.message == "studio.deleteAccount.signInFailed")
        #expect(rig.spy.calls.isEmpty)
    }

    @Test func offlineOnTheFirstCallSaysContentMayBeGone() async {
        let rig = await DeleteAccountRig(SpyDeletion(erases: [nil]))
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        #expect(model.message == "studio.deleteAccount.errorStarted")
        #expect(model.isError)
        #expect(rig.session.openDeletion(of: creator.id)?.stage == .erasing)
        #expect(!rig.spy.calls.contains("delete"))
    }

    @Test func someoneElseSigningInStopsItAndTheFirstAccountIsActiveAgain() async throws {
        let other = StudioAccount(id: "other", email: "amina.yusuf@example.org")
        let accounts = FixtureAccountService(
            signedIn: [creator], signedInAt: Date(timeIntervalSinceNow: -3600), stepUpAccount: other)
        let rig = await DeleteAccountRig(accounts: accounts)
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        await model.act()
        #expect(model.end == .otherAccount)
        #expect(rig.session.notice?.key == "studio.deleteAccount.signedInOther")
        #expect(await accounts.activeAccount()?.id == creator.id)
        #expect(rig.session.account?.id == creator.id)
        // Signed in here, so it is in the list at once.
        #expect(rig.session.accounts.map(\.id) == [creator.id, "other"])
        #expect(rig.spy.calls.isEmpty)
        #expect(try rig.records.all().isEmpty)
        #expect(rig.session.uploads.heldAccounts.isEmpty)
    }

    @Test func someoneElseAfterTheEraseSaysContentMayBeGone() async {
        let other = StudioAccount(id: "other", email: "amina.yusuf@example.org")
        let accounts = FixtureAccountService(
            signedIn: [creator], signedInAt: Date(timeIntervalSinceNow: -3600), stepUpAccount: other)
        let rig = await DeleteAccountRig(accounts: accounts, records: MemoryDeletionRecords([record(.contentErased)]))
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        #expect(model.message == "studio.deleteAccount.signInStarted")
        await model.act()
        #expect(rig.session.notice?.key == "studio.deleteAccount.signedInOtherStarted")
    }

    @Test func whenSwitchingBackFailsTheAppShowsWhoIsActive() async {
        let other = StudioAccount(id: "other", email: "amina.yusuf@example.org")
        let accounts = FixtureAccountService(
            signedIn: [creator], signedInAt: Date(timeIntervalSinceNow: -3600), stepUpAccount: other)
        let rig = await DeleteAccountRig(accounts: accounts)
        await accounts.fail(switching: CoreError.forbidden)
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        await model.act()
        #expect(rig.session.notice?.key == "studio.deleteAccount.signedInOtherStays")
        #expect(rig.session.account?.id == "other")
        #expect(rig.session.uploads.accountID == "other")
        #expect(rig.spy.calls.isEmpty)
    }

    @Test func aSecondFreshSignInAfterALongEraseStartsWithTheEraseAgain() async {
        let stale = DeletionAnswer(401, json: #"{"error":"insufficient_user_authentication","max_age":600}"#)
        let rig = await DeleteAccountRig(SpyDeletion(account: [stale, DeletionAnswer(200, json: #"{"deleted":true}"#)]))
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        #expect(model.action == .signIn)
        #expect(model.message == "studio.deleteAccount.signInContentErased")
        await model.act()
        await model.act()
        #expect(model.end == .deleted)
        #expect(rig.spy.calls == ["erase", "delete", "erase", "delete"])
    }

    @Test func whatStaysBehindIsSaidAndOnlyThatIsAccepted() async {
        let channel = DeletionAnswer(200, json: #"{"complete":true,"errors":["channel_unreadable:c"]}"#)
        let both = DeletionAnswer(200, json: #"{"complete":true,"errors":["channel_unreadable:c","search"]}"#)
        let rig = await DeleteAccountRig(SpyDeletion(erases: [channel, both, both]))
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        #expect(model.action == .deleteAnyway)
        #expect(model.message == "studio.deleteAccount.leftChannel")
        await model.act()
        #expect(model.message == "studio.deleteAccount.leftBoth")
        #expect(!rig.spy.calls.contains("delete"))
        await model.act()
        #expect(model.end == .deleted)
        #expect(rig.session.notice?.key == "studio.deleteAccount.doneBoth")
    }

    @Test func aNewDialogAsksForTheWordAgain() async {
        let channel = DeletionAnswer(200, json: #"{"complete":true,"errors":["channel_unreadable:c"]}"#)
        let rig = await DeleteAccountRig(SpyDeletion(erases: [channel]))
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        #expect(model.action == .deleteAnyway)
        #expect(!model.canAct(typed: ""))
        let reopened = DeleteAccountModel(account: creator, session: rig.session)
        #expect(reopened.action == .delete)
        #expect(!reopened.canAct(typed: ""))
        // What an earlier dialog was told is not accepted by this one.
        await reopened.act()
        #expect(reopened.action == .deleteAnyway)
        #expect(!rig.spy.calls.contains("delete"))
    }

    @Test func aWaitTheServerAskedForHoldsTheAction() async {
        let rig = await DeleteAccountRig(SpyDeletion(erases: [DeletionAnswer(503, json: "{}", retryAfter: "300")]))
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        #expect(model.message == "studio.deleteAccount.wait")
        #expect(!model.canAct(typed: "DELETE"))
        #expect(!model.canAct(typed: "DELETE", now: Date(timeIntervalSinceNow: 290)))
        #expect(model.canAct(typed: "DELETE", now: Date(timeIntervalSinceNow: 301)))
        #expect(model.cancel())
    }

    @Test func cancelWhileItRunsStopsAfterTheRequestThatIsOut() async {
        let spy = SpyDeletion(
            erases: [DeletionAnswer(200, json: #"{"complete":false,"resumeToken":"t"}"#)],
            onErase: { try? await Task.sleep(for: .milliseconds(200)) })
        let rig = await DeleteAccountRig(spy)
        let model = DeleteAccountModel(account: creator, session: rig.session)
        let run = Task { await model.act() }
        while !model.working || spy.calls.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.cancel())
        #expect(model.stopping)
        await run.value
        #expect(spy.calls == ["erase"])
        #expect(model.message == "studio.deleteAccount.stopped")
        #expect(model.cancel())
    }

    @Test func eitherWordCountsInEitherLanguageAndMarksDont() {
        for word in [
            "DELETE", "  delete \n", "حذف", "حَـذْف", "\u{200F}حذف\u{200E}", "\u{061C}حذف\u{061C}", "\u{2068}DELETE\u{2069}",
        ] { #expect(DeleteWord.matches(word), "\(word)") }
        for word in ["", "DEL", "DELETED", "حذ", "احذف"] { #expect(!DeleteWord.matches(word), "\(word)") }
    }

    @Test func everyNoticeOfADeletionIsTheBannersAndNoOtherIs() {
        for leftover: Set<DeletionLeftover> in [[], [.channel], [.other], [.channel, .other]] {
            #expect(StudioSession.deletedNotice(leftover: leftover, contentErased: true).isAboutDeletion)
        }
        #expect(StudioSession.deletedNotice(leftover: [], contentErased: false).isAboutDeletion)
        for key in ["studio.error.offline", "studio.error.signIn", "studio.error.generic"] {
            #expect(!StudioNotice(key).isAboutDeletion)
        }
    }

    // MARK: Restarts

    @Test(arguments: [DeletionStage.confirmed, .uploadsHeld]) func aRestartBeforeTheFirstCallShowsNothing(
        _ stage: DeletionStage
    ) async throws {
        let rig = await DeleteAccountRig(records: MemoryDeletionRecords([record(stage)]))
        #expect(rig.session.phase == .signedIn)
        #expect(rig.session.notice == nil)
        #expect(rig.session.openDeletions.isEmpty)
        #expect(try rig.records.all().isEmpty)
    }

    @Test(arguments: [DeletionStage.erasing, .contentErased]) func aRestartDuringItShowsItOpenAndErasesNothing(
        _ stage: DeletionStage
    ) async {
        let rig = await DeleteAccountRig(records: MemoryDeletionRecords([record(stage)]))
        #expect(rig.session.phase == .signedIn)
        #expect(rig.session.openDeletion(of: creator.id)?.stage == stage)
        #expect(!rig.spy.calls.contains("erase"))
    }

    @Test func aRestartAfterALostAnswerNeverShowsTheDeletedAccount() async throws {
        let rig = await DeleteAccountRig(
            SpyDeletion(states: [SpyDeletion.state(deleted: true)]), records: MemoryDeletionRecords([record(.deleteSent)]))
        #expect(rig.session.phase == .signedOut)
        #expect(rig.session.accounts.isEmpty)
        #expect(rig.session.notice?.key == "studio.deleteAccount.done")
        #expect(try rig.records.all().isEmpty)
    }

    @Test func aRestartWithoutAnAnswerHoldsUploadsAndCanAskAgain() async throws {
        let rig = await DeleteAccountRig(records: MemoryDeletionRecords([record(.deleteSent)]))
        #expect(rig.session.phase == .signedIn)
        #expect(rig.session.openDeletion(of: creator.id)?.stage == .deleteSent)
        #expect(rig.session.uploads.heldAccounts == [creator.id])
        await rig.session.checkDeletions()
        #expect(rig.session.phase == .signedIn)
        #expect(rig.session.notice == nil)
        await rig.session.checkDeletions(asked: true)
        #expect(rig.session.notice?.key == "studio.deleteAccount.stillUnknown")
        rig.spy.setStates([SpyDeletion.state(deleted: true)])
        await rig.session.checkDeletions(asked: true)
        #expect(rig.session.phase == .signedOut)
        #expect(rig.session.notice?.key == "studio.deleteAccount.done")
        #expect(try rig.records.all().isEmpty)
    }

    @Test func aRestartWhoseDeletionNeverArrivedLetsUploadsGoOn() async {
        let rig = await DeleteAccountRig(
            SpyDeletion(states: [SpyDeletion.state(deleted: false)]), records: MemoryDeletionRecords([record(.deleteSent)]))
        #expect(rig.session.openDeletion(of: creator.id)?.stage == .contentErased)
        #expect(rig.session.uploads.heldAccounts.isEmpty)
    }

    @Test func aDeletionNothingIsLeftToAskAboutCanBeDismissedOnceSignedOut() async throws {
        let rig = await DeleteAccountRig(
            SpyDeletion(states: [DeletionAnswer(401, json: #"{"error":"receipt_invalid"}"#)]),
            records: MemoryDeletionRecords([record(.deleteSent)]))
        // Nothing is held up by an answer that can't come any more.
        #expect(rig.session.openDeletion(of: creator.id)?.unsettled == true)
        #expect(rig.session.uploads.heldAccounts.isEmpty)
        #expect(rig.spy.calls == ["status"])
        await rig.session.checkDeletions(asked: true)
        #expect(rig.spy.calls == ["status"])
        await rig.session.signOut(creator.id)
        #expect(rig.session.signedOutDeletions.count == 1)
        rig.session.dismissDeletion(of: creator.id)
        #expect(rig.session.signedOutDeletions.isEmpty)
        #expect(try rig.records.all().isEmpty)
    }

    @Test func aDeletionThatCanStillBeAskedAboutCantBeDismissed() async throws {
        let rig = await DeleteAccountRig(records: MemoryDeletionRecords([record(.deleteSent)]))
        await rig.session.signOut(creator.id)
        rig.session.dismissDeletion(of: creator.id)
        #expect(try rig.records.all().count == 1)
    }

    @Test func byItselfTheAppAsksAtMostOnceAMinute() async {
        let rig = await DeleteAccountRig(records: MemoryDeletionRecords([record(.deleteSent)]))
        let before = rig.spy.calls.count
        await rig.session.checkDeletions()
        await rig.session.checkDeletions()
        #expect(rig.spy.calls.count == before + 1)
        await rig.session.checkDeletions(asked: true)
        #expect(rig.spy.calls.count == before + 2)
    }

    @Test func aSessionThatCantBeRemovedIsNeverShownSignedIn() async throws {
        let rig = await DeleteAccountRig()
        await rig.accounts.fail(signOut: CoreError.forbidden)
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        #expect(model.end == .deleted)
        #expect(rig.session.phase == .signedOut)
        #expect(rig.session.accounts.isEmpty)
        #expect(try rig.records.all().map(\.stage) == [.deleted])
        // Nor at the next start, which tries again.
        let again = StudioSession(
            services: rig.session.services, authenticator: FixtureWebAuthenticator(), defaults: rig.defaults)
        await again.start()
        #expect(again.phase == .signedOut)
        #expect(again.accounts.isEmpty)
        await rig.accounts.fail()
        let last = StudioSession(
            services: rig.session.services, authenticator: FixtureWebAuthenticator(), defaults: rig.defaults)
        await last.start()
        #expect(try rig.records.all().isEmpty)
        #expect(await rig.accounts.accounts().isEmpty)
    }

    @Test func aDeletedAccountThatCantBeRemovedNeverHidesTheOthers() async {
        let other = StudioAccount(id: "other", email: "amina.yusuf@example.org")
        let accounts = FixtureAccountService(signedIn: [creator, other])
        await accounts.fail(signOut: CoreError.forbidden)
        let rig = await DeleteAccountRig(accounts: accounts)
        await DeleteAccountModel(account: creator, session: rig.session).act()
        #expect(rig.session.account?.id == "other")
        #expect(await accounts.activeAccount()?.id == "other")
        #expect(rig.session.accounts.map(\.id) == ["other"])
    }

    @Test func signingInAgainAfterARestoreEndsAFinishedDeletion() async throws {
        let rig = await DeleteAccountRig(accounts: FixtureAccountService())
        try rig.records.save(record(.deleted))
        await rig.session.signIn()
        #expect(rig.session.account?.id == creator.id)
        #expect(rig.session.accounts.map(\.id) == [creator.id])
        #expect(try rig.records.all().isEmpty)
    }

    @Test func signingOutKeepsTheDeletionOpen() async throws {
        let rig = await DeleteAccountRig(records: MemoryDeletionRecords([record(.erasing)]))
        await rig.session.signOut(creator.id)
        #expect(rig.session.phase == .signedOut)
        #expect(rig.session.signedOutDeletions.map(\.label) == ["yusuf.rahman@example.org"])
        #expect(try rig.records.all().map(\.stage) == [.erasing])
    }
}

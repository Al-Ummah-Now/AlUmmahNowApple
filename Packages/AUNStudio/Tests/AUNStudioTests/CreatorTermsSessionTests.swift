import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

/// The session and the Creator Terms: what reads, agreements, refusals and account changes do.
@MainActor
struct CreatorTermsSessionTests {
    // MARK: Reads

    @Test func onlyAnExplicitNoGatesUpload() async {
        for (access, expected) in [
            (CreatorAccess.terms(true), CreatorTerms.accepted), (.terms(nil, nil), .off),
            (.terms(false), .required(.init(version: "2026-11-24"))),
        ] {
            #expect(await TermsTest.started(TermsStudioStub(access)).creatorTerms == expected)
        }
    }

    @Test func aFailedFirstReadLeavesUploadToTheServer() async {
        let studio = TermsStudioStub(.terms(false))
        await studio.failReads()
        let session = await TermsTest.started(studio)
        #expect(session.creatorTerms == .unknown)
        #expect(!session.needsCreatorTerms)
        await studio.answer(.terms(false))
        await session.refreshCreatorAccess()
        #expect(session.needsCreatorTerms)
    }

    @Test func aFailedReadKeepsWhatIsKnown() async {
        for access in [CreatorAccess.terms(false), .terms(true)] {
            let studio = TermsStudioStub(access)
            let session = await TermsTest.started(studio)
            session.setTermsAgreed(true)
            let before = session.creatorTerms
            await studio.failReads()
            await session.refreshCreatorAccess()
            #expect(session.creatorTerms == before)
        }
    }

    @Test func termsThatChangeAfterTheyWereAcceptedReadAsUpdated() async {
        let studio = TermsStudioStub(.terms(true, "v1"))
        let session = await TermsTest.started(studio)
        // Back in the app after v2 shipped.
        await studio.answer(.terms(false, "v2"))
        await session.refreshCreatorAccess()
        #expect(session.creatorTerms == .required(.init(version: "v2", updated: true)))
    }

    @Test func anAgreementToThisVersionThatIsGoneIsNotAnUpdate() async {
        let studio = TermsStudioStub(.terms(true, "v1"))
        let session = await TermsTest.started(studio)
        await studio.answer(.terms(false, "v1"))
        await session.refreshCreatorAccess()
        #expect(session.creatorTerms == .required(.init(version: "v1")))
    }

    @Test func anAnswerWithoutTermsForgetsNoKnownVersion() async {
        let studio = TermsStudioStub(.terms(true, "v1"))
        let session = await TermsTest.started(studio)
        await studio.answer(.terms(nil, nil))
        await session.refreshCreatorAccess()
        #expect(session.creatorTerms == .off)
        await studio.answer(.terms(false, "v2"))
        await session.refreshCreatorAccess()
        #expect(session.creatorTerms == .required(.init(version: "v2", updated: true)))
    }

    @Test func aVersionThatChangesUnderTheOpenGateClearsTheTick() async {
        let studio = TermsStudioStub(.terms(false, "v1"))
        let session = await TermsTest.started(studio)
        session.setTermsAgreed(true)
        await studio.answer(.terms(false, " v2 "))
        await session.refreshCreatorAccess()
        #expect(session.creatorTerms == .required(.init(version: "v2", updated: true, message: .updated)))
    }

    @Test func anOlderAnswerNeverReplacesANewerOne() async {
        let studio = TermsStudioStub(.terms(false, "v1"))
        let session = await TermsTest.started(studio)
        await studio.hold(.access)
        let late = Task { await session.refreshCreatorAccess() }
        await TermsTest.until { await studio.isHolding(.access) }
        await studio.answer(.terms(true, "v1"))
        let newer = Task { await session.refreshCreatorAccess() }
        await TermsTest.until { await studio.reads == 3 }
        await studio.release(.access)
        await late.value
        await newer.value
        #expect(session.creatorTerms == .accepted)
    }

    // MARK: Agreeing

    @Test func agreeingSendsTheVersionShown() async {
        let studio = TermsStudioStub(.terms(false, "v1"))
        let session = await TermsTest.started(studio)
        // Not ticked: nothing is sent.
        #expect(await !session.acceptCreatorTerms())
        #expect(await studio.posted.isEmpty)
        #expect(await TermsTest.agree(session))
        #expect(await studio.posted == ["v1"])
        #expect(session.creatorTerms == .accepted)
        #expect(session.creator?.termsAccepted == true)
    }

    @Test func aFailedAgreementSaysSoAndKeepsTheTick() async {
        let studio = TermsStudioStub(.terms(false, "v1"))
        let session = await TermsTest.started(studio)
        session.notice = StudioNotice("studio.error.signIn")
        await studio.acceptFails(.http(status: 503))
        #expect(await !TermsTest.agree(session))
        #expect(session.creatorTerms.gate?.message == .notSaved("studio.error.generic"))
        #expect(session.creatorTerms.gate?.agreed == true)
        #expect(session.creatorTerms.gate?.saving == false)
        // Another tap clears it, and other notices are left alone.
        await studio.acceptFails(nil)
        #expect(await session.acceptCreatorTerms())
        #expect(session.notice?.key == "studio.error.signIn")
    }

    @Test func aNewerVersionAtTheServerStaysAnUpdateUntilItIsAccepted() async {
        let studio = TermsStudioStub(.terms(false, "v1"))
        let session = await TermsTest.started(studio)
        await studio.acceptFails(TermsTest.changed(to: "v2"))
        #expect(await !TermsTest.agree(session))
        #expect(session.creatorTerms == .required(.init(version: "v2", updated: true, message: .updated)))
        session.dismissTermsMessage()
        #expect(session.creatorTerms == .required(.init(version: "v2", updated: true)))
        await studio.acceptFails(.offline)
        #expect(await !TermsTest.agree(session))
        #expect(session.creatorTerms.gate?.updated == true)
        #expect(session.creatorTerms.gate?.message == .notSaved("studio.error.offline"))
        await studio.acceptFails(nil)
        #expect(await session.acceptCreatorTerms())
        #expect(await studio.posted == ["v1", "v2", "v2"])
        #expect(session.creatorTerms == .accepted)
        // v2 is the known version now: asked again, it is not an update.
        await studio.answer(.terms(false, "v2"))
        await session.refreshCreatorAccess()
        #expect(session.creatorTerms == .required(.init(version: "v2")))
    }

    @Test func aNewerVersionWithoutItsNameIsReadBeforeItIsAccepted() async {
        let studio = TermsStudioStub(.terms(false, "v1"))
        let session = await TermsTest.started(studio)
        await studio.acceptFails(TermsTest.changed(to: nil))
        #expect(await !TermsTest.agree(session))
        await studio.acceptFails(nil)
        await studio.answer(.terms(false, "v2"))
        #expect(await !TermsTest.agree(session))
        #expect(await studio.posted == ["v1"])
        #expect(session.creatorTerms == .required(.init(version: "v2", updated: true, message: .updated)))
        #expect(await TermsTest.agree(session))
        #expect(await studio.posted == ["v1", "v2"])
    }

    /// The gate opened by a refusal while the server could not be read.
    private func unread(_ studio: TermsStudioStub) async -> StudioSession {
        await studio.failReads()
        let session = await TermsTest.started(studio)
        let reads = await studio.reads
        session.requireCreatorTerms(for: TermsTest.accountA)
        await TermsTest.until { await studio.reads > reads }
        return session
    }

    @Test func withoutAVersionAgreeingOnlyReadsAndSaysWhyTheBoxWasCleared() async {
        let studio = TermsStudioStub(.terms(false))
        let session = await unread(studio)
        #expect(session.creatorTerms == .required(.init(version: nil)))

        // Offline: it says so, and the tick stays for another try.
        #expect(await !TermsTest.agree(session))
        #expect(session.creatorTerms.gate?.message == .notRead("studio.error.offline"))
        #expect(session.creatorTerms.gate?.agreed == true)

        // Online again: the version is shown, not sent; the old error is gone and the cleared box is explained.
        await studio.answer(.terms(false, "v1"))
        #expect(await !session.acceptCreatorTerms())
        #expect(session.creatorTerms == .required(.init(version: "v1", message: .loaded)))
        #expect(await studio.posted.isEmpty)
        #expect(await TermsTest.agree(session))
        #expect(await studio.posted == ["v1"])
    }

    @Test func aReadThatBringsTheFirstVersionClearsAnEarlierTick() async {
        let studio = TermsStudioStub(.terms(false))
        let session = await unread(studio)
        session.setTermsAgreed(true)
        await studio.answer(.terms(false, "v1"))
        await session.refreshCreatorAccess()
        #expect(session.creatorTerms == .required(.init(version: "v1", message: .loaded)))
    }

    @Test func aServerThatGivesNoVersionIsNeverAgreedWith() async {
        let studio = TermsStudioStub(.terms(false, nil))
        let session = await TermsTest.started(studio)
        #expect(await !TermsTest.agree(session))
        #expect(session.creatorTerms.gate?.message == .notRead("studio.error.generic"))
        #expect(await studio.posted.isEmpty)
    }

    @Test func aSwitchTurnedOffOpensUpload() async {
        let studio = TermsStudioStub(.terms(false))
        let session = await TermsTest.started(studio)
        await studio.acceptFails(.featureOff)
        #expect(await TermsTest.agree(session))
        #expect(session.creatorTerms == .off)

        // Also when the gate has no version: the agreement reads that there is nothing to agree to.
        let other = TermsStudioStub(.terms(false))
        let second = await unread(other)
        await other.answer(.terms(nil, nil))
        #expect(await TermsTest.agree(second))
        #expect(second.creatorTerms == .off)
        #expect(await other.posted.isEmpty)
    }

    @Test func nothingElseHappensWhileTheAgreementIsSaved() async {
        let studio = TermsStudioStub(.terms(false))
        let session = await TermsTest.started(studio)
        await studio.acceptFails(.offline)
        #expect(await !TermsTest.agree(session))
        await studio.acceptFails(nil)
        let reads = await studio.reads
        await studio.hold(.accept)
        let saving = Task { await TermsTest.agree(session) }
        await TermsTest.until { await studio.isHolding(.accept) }
        #expect(session.isAcceptingTerms)
        #expect(session.creatorTerms.gate?.message == nil)
        session.setTermsAgreed(false)
        #expect(session.creatorTerms.gate?.agreed == true)
        #expect(await !session.acceptCreatorTerms())
        await session.refreshCreatorAccess()
        session.requireCreatorTerms(for: TermsTest.accountA)
        #expect(await studio.reads == reads)
        await studio.release(.accept)
        #expect(await saving.value)
        #expect(await studio.posted.count == 2)
        #expect(session.creatorTerms == .accepted)
    }

    @Test func aReadThatStartedBeforeTheAgreementIsDropped() async {
        let studio = TermsStudioStub(.terms(false))
        let session = await TermsTest.started(studio)
        await studio.hold(.access)
        let late = Task { await session.refreshCreatorAccess() }
        await TermsTest.until { await studio.isHolding(.access) }
        #expect(await TermsTest.agree(session))
        await studio.release(.access)
        await late.value
        #expect(session.creatorTerms == .accepted)
    }

    // MARK: Refusals

    @Test func aRefusalAsksAgainSoTheNewestVersionIsShown() async {
        let studio = TermsStudioStub(.terms(true, "v1"))
        let session = await TermsTest.started(studio)
        await studio.answer(.terms(false, "v2"))
        session.note(TermsTest.refusal, forAccount: TermsTest.accountA)
        #expect(session.needsCreatorTerms)
        await TermsTest.until { session.creatorTerms.gate?.version == "v2" }
        #expect(session.creatorTerms.gate?.updated == true)
        #expect(await TermsTest.agree(session))
        #expect(await studio.posted == ["v2"])
    }

    @Test func aLateRefusalOfAnotherAccountIsIgnored() async {
        let studio = TermsStudioStub(.terms(true))
        let session = await TermsTest.started(studio)
        session.note(TermsTest.refusal, forAccount: "another-account")
        session.requireCreatorTerms(for: "another-account")
        #expect(session.creatorTerms == .accepted)
    }

    /// The Content screen's model reports for the account it was made for.
    @Test func contentErrorsBelongToTheAccountOfTheScreen() async {
        let studio = TermsStudioStub(.terms(true))
        let session = await TermsTest.started(studio)
        let model = ContentView.model(for: session, channelID: "fixture-channel")
        await session.switchAccount(to: TermsTest.accountB.id)
        model.onError?(TermsTest.refusal)
        #expect(session.creatorTerms == .accepted)
        let own = ContentView.model(for: session, channelID: "fixture-channel")
        own.onError?(TermsTest.refusal)
        #expect(session.needsCreatorTerms)
    }

    // MARK: Accounts

    @Test func anAccountChangeForgetsTheTermsAndDropsALateAgreement() async {
        let studio = TermsStudioStub(.terms(false, "v1"))
        let session = await TermsTest.started(studio)
        await studio.hold(.accept)
        let late = Task { await TermsTest.agree(session) }
        await TermsTest.until { await studio.isHolding(.accept) }
        await studio.answer(.terms(false, "v2"))
        await session.switchAccount(to: TermsTest.accountB.id)
        // The other account's own gate: no tick, not saving, and its first version is not an update.
        #expect(session.creatorTerms == .required(.init(version: "v2")))
        await studio.release(.accept)
        #expect(await !late.value)
        #expect(session.creatorTerms == .required(.init(version: "v2")))
    }

    @Test func signingOutForgetsTheTerms() async {
        let studio = TermsStudioStub(.terms(false, "v1"))
        let session = await TermsTest.started(studio)
        await studio.hold(.accept)
        let late = Task { await TermsTest.agree(session) }
        await TermsTest.until { await studio.isHolding(.accept) }
        await session.signOut(TermsTest.accountB.id)
        await session.signOut(TermsTest.accountA)
        await studio.release(.accept)
        #expect(await !late.value)
        #expect(session.phase == .signedOut)
        #expect(session.creatorTerms == .unknown)
        #expect(session.knownTermsVersion == nil)
    }
}

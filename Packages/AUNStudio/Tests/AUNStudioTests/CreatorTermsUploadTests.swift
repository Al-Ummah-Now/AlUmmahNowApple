import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

/// Uploads and the Creator Terms: a refused one waits under the gate and goes on when it closes.
@MainActor
struct CreatorTermsUploadTests {
    private func state(_ session: StudioSession, _ job: UploadJob) -> UploadJob.State? {
        session.uploads.jobs.first { $0.id == job.id }?.state
    }

    @Test func aRefusedUploadWaitsUnderTheGateAndGoesOnOnceAccepted() async throws {
        let studio = TermsStudioStub(.terms(true))
        let session = await TermsTest.started(studio)
        await studio.refuseUploads(1)
        await studio.answer(.terms(false))
        let job = try TermsTest.job()
        session.uploads.enqueue([job])
        await TermsTest.until { state(session, job) == .paused && session.needsCreatorTerms }
        #expect(session.uploads.jobs.first?.failure == UploadQueue.termsRequiredKey)
        #expect(session.uploads.isBlocked)
        #expect(await TermsTest.agree(session))
        await TermsTest.until { state(session, job) == .done }
        #expect(state(session, job) == .done)
        #expect(await studio.initiated == 2)
    }

    @Test func aReadThatNoLongerAsksResumesTheUpload() async throws {
        let studio = TermsStudioStub(.terms(false))
        let session = await TermsTest.started(studio)
        await studio.refuseUploads(1)
        let job = try TermsTest.job()
        session.uploads.enqueue([job])
        await TermsTest.until { state(session, job) == .paused }
        // The refusal's own read; then the switch is off.
        await TermsTest.until { await studio.reads == 2 }
        await studio.answer(.terms(nil, nil))
        await session.refreshCreatorAccess()
        #expect(session.creatorTerms == .off)
        await TermsTest.until { state(session, job) == .done }
        #expect(state(session, job) == .done)
    }

    @Test func aRefusalWhileTheServerSaysNothingDoesNotLoop() async throws {
        let studio = TermsStudioStub(.terms(nil, nil))
        let session = await TermsTest.started(studio)
        await studio.refuseUploads()
        let job = try TermsTest.job()
        session.uploads.enqueue([job])
        await TermsTest.until { session.creatorTerms.gate?.message != nil }
        #expect(session.creatorTerms == .required(.init(version: nil, message: .notRead("studio.error.generic"))))
        #expect(state(session, job) == .paused)
        #expect(await studio.initiated == 1)
        // A tap asks again, and cannot loop: there is nothing to agree to.
        await studio.refuseUploads(0)
        #expect(await TermsTest.agree(session))
        await TermsTest.until { state(session, job) == .done }
        #expect(state(session, job) == .done)
    }

    /// Servers that disagree: the read says accepted, the upload is refused.
    @Test func eachUploadIsResumedByItselfTwiceAtMost() async throws {
        let studio = TermsStudioStub(.terms(true))
        let session = await TermsTest.started(studio)
        await studio.refuseUploads()
        let job = try TermsTest.job()
        session.uploads.enqueue([job])
        await TermsTest.until { session.needsCreatorTerms && session.creatorTerms.gate?.message != nil }
        #expect(await studio.initiated == 3)
        #expect(state(session, job) == .paused)
        #expect(session.creatorTerms.gate?.message == .notRead("studio.error.generic"))
    }

    @Test func uploadsRefusedTogetherEachHaveTheirOwnResumes() async throws {
        let studio = TermsStudioStub(.terms(true))
        let session = await TermsTest.started(studio)
        await studio.refuseUploads()
        let jobs = [try TermsTest.job(0), try TermsTest.job(1)]
        session.uploads.enqueue(jobs)
        await TermsTest.until {
            session.creatorTerms.gate?.message != nil && jobs.allSatisfy { state(session, $0) == .paused }
        }
        // Three tries each, however their refusals and reads fall together.
        #expect(await studio.initiated == 6)
    }

    @Test func anUploadThatFinishedLeavesTheNextOneItsOwnResumes() async throws {
        let studio = TermsStudioStub(.terms(true))
        let session = await TermsTest.started(studio)
        for tries in [3, 6] {
            // Refused twice, resumed by itself twice, then taken.
            await studio.refuseUploads(2)
            let job = try TermsTest.job()
            session.uploads.enqueue([job])
            await TermsTest.until { state(session, job) == .done }
            #expect(state(session, job) == .done)
            #expect(await studio.initiated == tries)
        }
        #expect(session.creatorTerms == .accepted)
    }

    @Test func anAgreementStartsTheResumesOver() async throws {
        let studio = TermsStudioStub(.terms(true))
        let session = await TermsTest.started(studio)
        await studio.refuseUploads()
        let job = try TermsTest.job()
        session.uploads.enqueue([job])
        await TermsTest.until { session.creatorTerms.gate?.message != nil }
        #expect(await studio.initiated == 3)
        await studio.refuseUploads(2)
        #expect(await TermsTest.agree(session))
        await TermsTest.until { state(session, job) == .done }
        #expect(state(session, job) == .done)
        #expect(await studio.initiated == 6)
    }

    @Test func anUploadAtItsLimitDoesNotHoldBackAnother() async throws {
        let studio = TermsStudioStub(.terms(true))
        let session = await TermsTest.started(studio)
        await studio.refuseUploads()
        let stuck = try TermsTest.job(0)
        session.uploads.enqueue([stuck])
        await TermsTest.until { session.creatorTerms.gate?.message != nil }
        var other = try TermsTest.job(1)
        other.state = .paused
        other.failure = UploadQueue.termsRequiredKey
        session.uploads.enqueue([other])
        await studio.refuseUploads(0)
        await session.refreshCreatorAccess(afterRefusal: true)
        await TermsTest.until { state(session, other) == .done }
        #expect(state(session, other) == .done)
        #expect(state(session, stuck) == .paused)
        #expect(session.creatorTerms.gate?.message == .notRead("studio.error.generic"))
    }

    @Test func aSwitchTurnedOffWhileAgreeingResumesTheUpload() async throws {
        let studio = TermsStudioStub(.terms(false))
        let session = await TermsTest.started(studio)
        await studio.refuseUploads(1)
        let job = try TermsTest.job()
        session.uploads.enqueue([job])
        await TermsTest.until { state(session, job) == .paused }
        await studio.acceptFails(.featureOff)
        await TermsTest.until { await studio.reads == 2 }
        #expect(await TermsTest.agree(session))
        await TermsTest.until { state(session, job) == .done }
        #expect(state(session, job) == .done)
    }

    @Test func anAgreementResumesOnlyTheUploadsOfItsAccount() async throws {
        let studio = TermsStudioStub(.terms(false))
        let session = await TermsTest.started(studio)
        var deletion = try TermsTest.job(0)
        deletion.state = .paused
        deletion.failure = UploadQueue.accountStateKey
        var waiting = try TermsTest.job(1)
        waiting.state = .paused
        waiting.failure = UploadQueue.termsRequiredKey
        session.uploads.enqueue([deletion, waiting])

        await session.switchAccount(to: TermsTest.accountB.id)
        await studio.refuseUploads(1)
        let own = try TermsTest.job(2, account: TermsTest.accountB.id)
        session.uploads.enqueue([own])
        await TermsTest.until { state(session, own) == .paused && session.creatorTerms.gate?.version != nil }
        #expect(await TermsTest.agree(session))
        await TermsTest.until { state(session, own) == .done }
        #expect(state(session, own) == .done)
        #expect(state(session, deletion) == .paused && state(session, waiting) == .paused)
    }

    @Test func aLateRefusalOfAnotherAccountsUploadGatesNobody() async throws {
        let studio = TermsStudioStub(.terms(true))
        let session = await TermsTest.started(studio)
        await studio.refuseUploads(1)
        await studio.hold(.initiate)
        let job = try TermsTest.job()
        session.uploads.enqueue([job])
        await TermsTest.until { await studio.isHolding(.initiate) }
        await session.switchAccount(to: TermsTest.accountB.id)
        await studio.release(.initiate)
        await TermsTest.until { state(session, job) == .paused || state(session, job) == .waiting }
        #expect(session.creatorTerms == .accepted)
        #expect(!session.uploads.isBlocked)
    }

    @Test func theTermsNeverEndAnAccountBlock() async throws {
        let studio = TermsStudioStub(CreatorAccess(pendingDeletion: true))
        let session = await TermsTest.started(studio)
        await studio.refuseUploads(with: .refused(Refusal(code: Refusal.accountPendingDeletion)))
        let job = try TermsTest.job()
        session.uploads.enqueue([job])
        await TermsTest.until { session.uploads.isBlocked }
        session.uploads.remove(job.id)
        await session.refreshCreatorAccess()
        #expect(session.uploads.isBlocked)
    }

    @Test func aWaitingRowOffersResumeOnlyWithoutTheGate() throws {
        var job = try TermsTest.job()
        job.state = .paused
        job.failure = UploadQueue.termsRequiredKey
        #expect(UploadJobRow.pausedStatusKey(for: job) == "studio.upload.state.waitingForTerms")
        #expect(!UploadJobRow.showsResumeAction(for: job, isTermsGateOpen: true))
        #expect(UploadJobRow.showsResumeAction(for: job, isTermsGateOpen: false))
        job.failure = nil
        #expect(UploadJobRow.pausedStatusKey(for: job) == "studio.upload.state.paused")
        #expect(UploadJobRow.showsResumeAction(for: job, isTermsGateOpen: true))
    }
}

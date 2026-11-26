import Foundation
import Testing

@testable import AUNCoreBridge

@MainActor @Suite struct AccountDeletionRestartTests {
    @Test(arguments: [DeletionStage.confirmed, .uploadsHeld]) func aRestartBeforeTheFirstCallDropsTheRecord(
        _ stage: DeletionStage
    ) async throws {
        let rig = DeletionRig(deletionRecord(stage))
        #expect(try await rig.deletion.settle().isEmpty)
        #expect(rig.record == nil)
        #expect(rig.log.all.isEmpty)
    }

    @Test(arguments: [DeletionStage.erasing, .contentErased]) func aRestartDuringTheEraseKeepsItOpenAndErasesNothing(
        _ stage: DeletionStage
    ) async throws {
        let saved = deletionRecord(stage, resumeToken: "t1", leftover: [.channel])
        let rig = DeletionRig(saved)
        #expect(try await rig.deletion.settle() == [.open(saved)])
        #expect(rig.record == saved)
        #expect(rig.log.all == ["status"])
    }

    @Test func aRestartAfterALostAnswerFinishesWhatAuthSaysIsDone() async throws {
        let saved = deletionRecord(.deleteSent)
        let rig = DeletionRig(saved)
        rig.service.states = [accountState(deleted: true)]
        #expect(try await rig.deletion.settle() == [.deleted(saved)])
        #expect(rig.log.all == ["status", "purge", "end", "forget"])
        #expect(rig.record == nil)
    }

    @Test func aRestartAfterALostAnswerThatNeverArrivedIsOpen() async throws {
        let rig = DeletionRig(deletionRecord(.deleteSent))
        _ = try await rig.deletion.settle()
        #expect(rig.record?.stage == .contentErased)
        #expect(rig.log.all == ["status"])
    }

    @Test func aRestartWithoutAnAnswerStaysUnknown() async throws {
        for answer in [nil, DeletionAnswer(429, json: "{}"), DeletionAnswer(status: 500)] {
            let saved = deletionRecord(.deleteSent)
            let rig = DeletionRig(saved)
            rig.service.states = [answer]
            #expect(try await rig.deletion.settle() == [.unknown(saved)])
            #expect(rig.record == saved)
        }
    }

    @Test func aRestartFinishesTheCleanUpWithoutTheServer() async throws {
        let saved = deletionRecord(.deleted)
        let rig = DeletionRig(saved)
        rig.service.states = [nil]
        #expect(try await rig.deletion.settle() == [.cleaned(saved)])
        #expect(rig.log.all == ["status", "purge", "end", "forget"])
        #expect(rig.record == nil)
        #expect(try await rig.deletion.settle().isEmpty)
    }

    @Test func anAccountRestoredBeforeTheCleanUpKeepsItsSession() async throws {
        let rig = DeletionRig(deletionRecord(.deleted))
        #expect(try await rig.deletion.settle().isEmpty)
        #expect(rig.log.all == ["status"])
        #expect(rig.record == nil)
    }

    @Test func cleanUpThatFailsIsStillADeletionAndIsFinishedLater() async throws {
        for purge in [true, false] {
            let rig = DeletionRig()
            if purge { rig.device.purgeError = URLError(.cannotRemoveFile) } else { rig.device.endError = CoreError.forbidden }
            #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
            // The session ends also when the uploads could not be removed.
            #expect(rig.log.all.contains("end"))
            #expect(!rig.log.all.contains("forget"))
            #expect(rig.record?.stage == .deleted)
            rig.device.purgeError = nil
            rig.device.endError = nil
            rig.service.states = [accountState(deleted: true)]
            _ = try await rig.deletion.settle()
            #expect(rig.record == nil)
            #expect(rig.log.all.last == "forget")
        }
    }

    @Test func aRunUnderWayIsNeitherStartedTwiceNorSettledByAnotherWindow() async throws {
        let rig = DeletionRig()
        let other = AccountDeletion(records: rig.records, service: rig.service, device: rig.device)
        var second: DeletionOutcome?
        var settled: [AccountDeletion.Settled]?
        rig.device.onHold = {
            second = await other.run("u1", label: "u1")
            settled = try? await other.settle()
        }
        #expect(await rig.run() == .deleted(leftover: [], contentErased: true))
        #expect(second == .failed(.some))
        #expect(settled == [])
        #expect(rig.log.erases == 1)
    }

    @Test func aRestartWhoseReceiptIsRefusedAsksOnceAndLeavesItToThePerson() async throws {
        let rig = DeletionRig(deletionRecord(.deleteSent))
        rig.service.states = [DeletionAnswer(401, json: #"{"error":"receipt_invalid"}"#)]
        for _ in 0..<3 {
            let settled = try await rig.deletion.settle()
            #expect(settled.count == 1)
            guard case .open = settled.first else {
                Issue.record("not open")
                return
            }
        }
        #expect(rig.log.all == ["status"])
        #expect(rig.record?.unsettled == true)
    }

    @Test func settlingTwiceIsTheSameAsOnce() async throws {
        let rig = DeletionRig(deletionRecord(.deleteSent))
        let first = try await rig.deletion.settle()
        #expect(first.count == 1)
        let once = rig.record
        _ = try await rig.deletion.settle()
        #expect(rig.record == once)
    }
}

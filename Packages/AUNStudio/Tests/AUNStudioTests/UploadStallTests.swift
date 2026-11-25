import Foundation
import Testing

@testable import AUNStudio

struct UploadStallTests {
    @Test func returnsTheResultOfAnOperationThatFinishes() async throws {
        let value = try await guardedByStall(limit: .seconds(5)) { 41 + 1 }
        #expect(value == 42)
    }

    @Test func throwsStalledWhenNothingShowsLifeForTheLimit() async throws {
        let started = ContinuousClock.now
        await #expect(throws: UploadStalled.self) {
            try await guardedByStall(limit: .milliseconds(120)) { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func anOperationThatKeepsTouchingItsActivityIsNeverStalled() async throws {
        let activity = UploadActivity()
        let value = try await guardedByStall(limit: .milliseconds(120), activity: activity) { () -> Int in
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(30))
                activity.touch()
            }
            return 7
        }
        #expect(value == 7)
    }

    @Test func anOperationThatIgnoresCancellationIsStillAbandonedAtTheLimit() async throws {
        // A call into Core cannot be cancelled: the caller must not wait for it
        let started = ContinuousClock.now
        await #expect(throws: UploadStalled.self) {
            try await guardedByStall(limit: .milliseconds(120)) { () -> Int in
                await Task { try? await Task.sleep(for: .seconds(3)) }.value
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func cancellingTheCallerCancelsTheOperationAndThrowsCancellation() async throws {
        let task = Task {
            try await guardedByStall(limit: .seconds(30)) { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func anErrorFromTheOperationPassesThroughAsItIs() async throws {
        struct Boom: Error, Equatable {}
        await #expect(throws: Boom.self) { try await guardedByStall(limit: .seconds(5)) { () -> Int in throw Boom() } }
    }
}

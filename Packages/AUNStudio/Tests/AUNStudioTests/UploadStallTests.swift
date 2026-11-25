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

    /// A clock the test moves by hand
    private final class ManualTime: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Duration = .zero
        func advance(_ by: Duration) { lock.withLock { value += by } }
        var now: Duration { lock.withLock { value } }
    }

    @Test func aWholeSuspensionOfTheAppIsNotTimeTheServerWasSilent() async throws {
        // iOS keeps a background upload going while the app is frozen: no callback reaches it, and when it wakes the
        // clock is far ahead. The window starts again; the upload is not failed.
        let time = ManualTime()
        let activity = UploadActivity(now: { time.now })
        let task = Task {
            try await guardedByStall(limit: .milliseconds(200), activity: activity, tick: .milliseconds(10)) { () -> Int in
                try await Task.sleep(for: .milliseconds(150))
                time.advance(.seconds(600))  // the app was suspended for ten minutes
                try await Task.sleep(for: .milliseconds(150))
                return 5
            }
        }
        #expect(try await task.value == 5)
    }

    @Test func silenceThatIsOursToCountStillStalls() async throws {
        // The same clock, moving in small steps while the process runs: no bytes for the limit is a stall
        let time = ManualTime()
        let activity = UploadActivity(now: { time.now })
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                time.advance(.milliseconds(10))
            }
        }
        defer { ticker.cancel() }
        await #expect(throws: UploadStalled.self) {
            try await guardedByStall(limit: .milliseconds(300), activity: activity, tick: .milliseconds(20)) { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
    }
}

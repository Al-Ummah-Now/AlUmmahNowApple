import AUNCoreBridge
import Testing

@testable import AUNStudio

/// No endless spinners (owner review 2026-11-16): every load ends in content, an empty state, hidden, or an error with
/// Retry, never in `loading`, whatever the answer.
@MainActor
struct LoadPhaseTests {
    private func run(from previous: LoadPhase = .idle, _ load: () async throws -> Bool) async -> [LoadPhase] {
        var seen: [LoadPhase] = []
        await LoadPhase.run(from: previous, set: { seen.append($0) }, load)
        return seen
    }

    @Test func contentEndsReady() async {
        #expect(await run { false } == [.loading, .ready])
    }

    @Test func noDataEndsInTheEmptyState() async {
        #expect(await run { true } == [.loading, .empty])
    }

    @Test(arguments: [
        CoreError.featureOff, .http(status: 402), .refused(Refusal(code: Refusal.upgradeRequired)),
        .refused(Refusal(code: Refusal.uploadsByInvitation)),
        .forbidden,
    ])
    func featureOffAndRefusalsEndHidden(error: CoreError) async {
        #expect(await run { throw error } == [.loading, .hidden])
    }

    @Test func notFoundEndsInTheEmptyState() async {
        #expect(await run { throw CoreError.notFound } == [.loading, .empty])
    }

    @Test func anErrorEndsFailedWithRetry() async {
        #expect(await run { throw CoreError.http(status: 500) } == [.loading, .failed])
        #expect(await run { throw CoreError.offline } == [.loading, .failed])
    }

    @Test func cancellationStopsTheSpinner() async {
        #expect(await run { throw CancellationError() } == [.loading, .idle])
        #expect(await run { throw CoreError.cancelled } == [.loading, .idle])
    }

    @Test func aFailedOrCancelledReloadKeepsWhatWasShown() async {
        #expect(await run(from: .ready) { throw CancellationError() } == [.loading, .ready])
        #expect(await run(from: .ready) { throw CoreError.offline } == [.loading, .ready])
        #expect(await run(from: .empty) { throw CoreError.notFound } == [.loading, .empty])
        #expect(await run(from: .ready) { throw CoreError.featureOff } == [.loading, .hidden])
    }

    @Test func aRealCancelledTaskEndsTooNotLoading() async {
        var last: LoadPhase = .idle
        let task = Task { @MainActor in
            await LoadPhase.run(from: .idle, set: { last = $0 }) {
                try await Task.sleep(for: .seconds(30))
                return false
            }
        }
        while last != .loading { await Task.yield() }
        task.cancel()
        await task.value
        #expect(last == .idle)
        #expect(!last.isLoading)
    }
}

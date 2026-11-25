import Foundation

/// A step of an upload that gave no sign of life for too long: the request was sent and nothing came back, or a
/// chunk stopped moving. The job stops with a message and Retry instead of sitting at "Uploading, 0%" (Apple #105).
struct UploadStalled: Error, Equatable {}

/// When a step last showed life. A chunk touches it as bytes leave; a step that never touches it is judged by how
/// long it has run.
final class UploadActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now

    func touch() { lock.withLock { last = .now } }

    var idle: Duration { lock.withLock { ContinuousClock.now - last } }
}

/// One outcome for a race between an operation and its watchdog: whichever finishes first resumes the caller, the
/// other is cancelled. The operation is not awaited after that, so one that ignores cancellation (a call into Core)
/// cannot keep the caller waiting.
private final class StallRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var tasks: [Task<Void, Never>] = []
    private var finished = false
    private var cancelledEarly = false

    /// False when the caller was cancelled before the race began (the continuation is resumed here).
    func start(_ continuation: CheckedContinuation<T, any Error>) -> Bool {
        let early = lock.withLock { () -> Bool in
            if cancelledEarly {
                finished = true
                return true
            }
            self.continuation = continuation
            return false
        }
        if early { continuation.resume(throwing: CancellationError()) }
        return !early
    }

    func add(_ task: Task<Void, Never>) {
        let stop = lock.withLock { () -> Bool in
            if finished { return true }
            tasks.append(task)
            return false
        }
        if stop { task.cancel() }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, tasks) = lock.withLock { () -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
            guard !finished else { return (nil, []) }
            finished = true
            defer {
                self.continuation = nil
                self.tasks = []
            }
            return (self.continuation, self.tasks)
        }
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }

    func cancel() {
        let settled = lock.withLock { () -> Bool in
            cancelledEarly = true
            return continuation != nil
        }
        if settled { finish(.failure(CancellationError())) }
    }
}

/// Runs `operation`; throws `UploadStalled` when `activity` has been idle for `limit`. Cancelling the caller cancels
/// the operation and throws `CancellationError`.
func guardedByStall<T: Sendable>(
    limit: Duration, activity: UploadActivity = UploadActivity(), tick: Duration? = nil,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = StallRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            guard race.start(continuation) else { return }
            race.add(
                Task {
                    do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
                })
            let step = tick ?? max(.milliseconds(5), min(limit / 4, .seconds(5)))
            race.add(
                Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: step)
                        if activity.idle > limit {
                            race.finish(.failure(UploadStalled()))
                            return
                        }
                    }
                })
        }
    } onCancel: {
        race.cancel()
    }
}

import Foundation

/// A step of an upload that gave no sign of life for too long: the request was sent and nothing came back, or a
/// chunk stopped moving. The job stops with a message and Retry instead of sitting at "Uploading, 0%" (Apple #105).
struct UploadStalled: Error, Equatable {}

/// When a step last showed life, on a clock that stops while the device sleeps (`SuspendingClock`). A chunk touches it
/// as bytes leave; a step that never touches it is judged by how long it has run. `now` is injectable for tests.
final class UploadActivity: @unchecked Sendable {
    private static let origin = SuspendingClock.now
    /// Time since the process started counting, not counting system sleep.
    static let systemNow: @Sendable () -> Duration = { SuspendingClock.now - origin }

    let now: @Sendable () -> Duration
    private let lock = NSLock()
    private var last: Duration

    init(now: @escaping @Sendable () -> Duration = UploadActivity.systemNow) {
        self.now = now
        last = now()
    }

    func touch() { touch(at: now()) }

    func touch(at current: Duration) { lock.withLock { last = current } }

    var idle: Duration { idle(at: now()) }

    func idle(at current: Duration) -> Duration { lock.withLock { current - last } }
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
                    var lastTick = activity.now()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: step)
                        guard !Task.isCancelled else { return }
                        let current = activity.now()
                        // The app was suspended (iOS keeps a background upload going while this process is frozen, so no
                        // callback reached it) or the device slept: the silence was ours, not the server's. Start the
                        // window again from here.
                        if current - lastTick > step * 3 { activity.touch(at: current) }
                        lastTick = current
                        if activity.idle(at: current) > limit {
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

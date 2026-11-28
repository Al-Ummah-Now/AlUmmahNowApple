import AUNCoreBridge
import AUNSignalTrap
import Foundation
import os

final class TrackedLock: @unchecked Sendable {
    private let underlying = NSLock()
    private let owner = OSAllocatedUnfairLock<Int>(initialState: 0)

    private static var currentThreadID: Int { Int(bitPattern: pthread_self()) }

    var isHeldByCurrentThread: Bool {
        let current = Self.currentThreadID
        return owner.withLock { $0 == current }
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        underlying.lock()
        let current = Self.currentThreadID
        owner.withLock { $0 = current }
        defer {
            owner.withLock { $0 = 0 }
            underlying.unlock()
        }
        return try body()
    }

    func tryWithLock<T>(timeout: TimeInterval, _ body: () -> T) -> T? {
        if isHeldByCurrentThread { return nil }
        let acquired = underlying.try() || underlying.lock(before: Date(timeIntervalSinceNow: timeout))
        guard acquired else { return nil }
        let current = Self.currentThreadID
        owner.withLock { $0 = current }
        defer {
            owner.withLock { $0 = 0 }
            underlying.unlock()
        }
        return body()
    }
}

/// Process-wide uncaught NSException & async-signal-safe fatal POSIX signal bridge (captures Swift
/// `fatalError` / `SIGTRAP` / `SIGILL` / `SIGABRT` / `SIGSEGV` / `SIGBUS` / `SIGFPE` to a marker file
/// consumed on next opted-in launch, and chains previously installed handlers).
public enum CrashTelemetryHook {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var installed = false
    private nonisolated(unsafe) static var activeService: (any TelemetryServicing)?
    private nonisolated(unsafe) static var activeServiceID: ObjectIdentifier?
    private nonisolated(unsafe) static var previousHandler: (@convention(c) (NSException) -> Void)?

    static var isSignalTrapInstalled: Bool { aun_signal_trap_is_installed() }

    public static func install(service: any TelemetryServicing) {
        lock.withLock {
            activeService = service
            activeServiceID = (service as? CoreTelemetryService).map(ObjectIdentifier.init)
            guard !installed else { return }
            installed = true
            previousHandler = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { CrashTelemetryHook.handle($0) }
        }
        // Synchronize signal capture OUTSIDE CrashTelemetryHook.lock so lock order is strictly
        // CoreTelemetryService.lock -> CrashTelemetryHook.lock -> AUNSignalTrap.g_mutex.
        if let core = service as? CoreTelemetryService {
            core.syncCrashSignalCapture()
        } else {
            lock.withLock { aun_signal_trap_disable() }
        }
    }

    static func updateSignalCapture(for service: CoreTelemetryService, enabled: Bool, markerPath: String?) {
        lock.withLock {
            guard activeServiceID == ObjectIdentifier(service) else { return }
            if enabled, let markerPath, !markerPath.isEmpty {
                markerPath.withCString { aun_signal_trap_enable($0) }
            } else {
                aun_signal_trap_disable()
            }
        }
    }

    static func parseSignalMarker(at markerPath: String) -> (String, Int64)? {
        guard
            let raw = (try? String(contentsOfFile: markerPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        let parts = raw.split(separator: " ", maxSplits: 1)
        let signalName = String(parts[0])
        let allowed: Set<String> = ["SIGTRAP", "SIGILL", "SIGABRT", "SIGSEGV", "SIGBUS", "SIGFPE"]
        guard allowed.contains(signalName) else { return nil }
        if parts.count > 1, let parsedMs = Int64(parts[1]), parsedMs > 0 {
            return (signalName, parsedMs)
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: markerPath)[.modificationDate] as? Date)
        let fallbackMs = Int64((mtime ?? Date()).timeIntervalSince1970 * 1000)
        return (signalName, max(1, fallbackMs))
    }

    static func bufferContainsSignalCrash(
        at bufferPath: String?, signalName: String, occurredAtMs: Int64
    ) -> Bool {
        guard let bufferPath,
            let data = try? Data(contentsOf: URL(fileURLWithPath: bufferPath)),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let events = root["events"] as? [[String: Any]]
        else {
            return false
        }
        return events.contains { event in
            guard (event["kind"] as? String) == "crash",
                (event["name"] as? String) == "crash",
                let props = event["properties"] as? [String: Any],
                (props["kind"] as? String) == "FatalSignal",
                (props["message"] as? String) == signalName,
                let fromPrev = props["from_previous_session"],
                (fromPrev as? Bool) != false,
                let ts = props["occurred_at_ms"] as? NSNumber
            else { return false }
            return ts.int64Value == occurredAtMs
        }
    }

    static func clearConsumedSignalMarker(for bufferPath: String?) {
        guard let markerPath = bufferPath.map({ $0 + ".crash-signal" }), !markerPath.isEmpty else { return }
        if !CoreTelemetryService.removeSingleFile(atPath: markerPath) {
            _ = truncate(markerPath, 0)
        }
    }

    private static func handle(_ exception: NSException) {
        let (service, previous) = lock.withLock { (activeService, previousHandler) }
        let kind = exception.name.rawValue
        let message = kind.isEmpty ? "Uncaught NSException" : kind
        let stack = exception.callStackSymbols.joined(separator: "\n")
        if let core = service as? CoreTelemetryService {
            core.reportCrashBestEffort(kind: kind, message: message, stack: stack)
        } else {
            service?.reportCrash(kind: kind, message: message, stack: stack, fromPreviousSession: false)
        }
        previous?(exception)
    }
}

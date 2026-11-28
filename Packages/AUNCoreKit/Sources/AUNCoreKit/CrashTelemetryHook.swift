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
    private nonisolated(unsafe) static var previousHandler: (@convention(c) (NSException) -> Void)?

    static var isSignalTrapInstalled: Bool { aun_signal_trap_is_installed() }

    public static func install(service: any TelemetryServicing) {
        lock.withLock {
            activeService = service
            guard !installed else { return }
            installed = true
            previousHandler = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { CrashTelemetryHook.handle($0) }
        }
        // Synchronize signal capture OUTSIDE CrashTelemetryHook.lock so lock order is strictly
        // CoreTelemetryService.lock -> AUNSignalTrap.g_mutex (never inverted against revocation).
        if let core = service as? CoreTelemetryService {
            core.syncCrashSignalCapture()
        } else {
            aun_signal_trap_disable()
        }
    }

    static func updateSignalCapture(enabled: Bool, markerPath: String?) {
        if enabled, let markerPath, !markerPath.isEmpty {
            markerPath.withCString { aun_signal_trap_enable($0) }
        } else {
            aun_signal_trap_disable()
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

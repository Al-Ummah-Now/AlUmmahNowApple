import AUNCoreBridge
import Foundation

/// Process-wide uncaught NSException & async-signal-safe fatal POSIX signal bridge (captures Swift
/// `fatalError` / `SIGTRAP` / `SIGILL` / `SIGABRT` / `SIGSEGV` / `SIGBUS` / `SIGFPE` to a marker file
/// consumed on next opted-in launch, and chains any previously installed `NSException` handler).
public enum CrashTelemetryHook {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var installed = false
    private nonisolated(unsafe) static var activeService: (any TelemetryServicing)?
    private nonisolated(unsafe) static var previousHandler: (@convention(c) (NSException) -> Void)?
    private nonisolated(unsafe) static var signalMarkerCPath: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var signalCaptureEnabled: sig_atomic_t = 0
    private nonisolated(unsafe) static var sigTrapMsg: UnsafePointer<CChar>?
    private nonisolated(unsafe) static var sigIllMsg: UnsafePointer<CChar>?
    private nonisolated(unsafe) static var sigAbrtMsg: UnsafePointer<CChar>?
    private nonisolated(unsafe) static var sigSegvMsg: UnsafePointer<CChar>?
    private nonisolated(unsafe) static var sigBusMsg: UnsafePointer<CChar>?
    private nonisolated(unsafe) static var sigFpeMsg: UnsafePointer<CChar>?

    public static func install(service: any TelemetryServicing) {
        lock.withLock {
            activeService = service
            let core = service as? CoreTelemetryService
            updateSignalCaptureLocked(enabled: service.consent != .off, markerPath: core?.signalCrashMarkerPath)
            guard !installed else { return }
            installed = true
            previousHandler = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { CrashTelemetryHook.handle($0) }
            installFatalSignalHandlersLocked()
        }
    }

    static func updateSignalCapture(enabled: Bool, markerPath: String?) {
        lock.withLock {
            updateSignalCaptureLocked(enabled: enabled, markerPath: markerPath)
        }
    }

    private static func updateSignalCaptureLocked(enabled: Bool, markerPath: String?) {
        signalCaptureEnabled = 0
        if let markerPath, !markerPath.isEmpty {
            let dup = strdup(markerPath)
            signalMarkerCPath = dup
            signalCaptureEnabled = enabled ? 1 : 0
        }
    }

    private static func installFatalSignalHandlersLocked() {
        sigTrapMsg = UnsafePointer(strdup("SIGTRAP\n"))
        sigIllMsg = UnsafePointer(strdup("SIGILL\n"))
        sigAbrtMsg = UnsafePointer(strdup("SIGABRT\n"))
        sigSegvMsg = UnsafePointer(strdup("SIGSEGV\n"))
        sigBusMsg = UnsafePointer(strdup("SIGBUS\n"))
        sigFpeMsg = UnsafePointer(strdup("SIGFPE\n"))
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { sig in CrashTelemetryHook.handleFatalSignal(sig) }
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESETHAND
        for sig in [SIGTRAP, SIGILL, SIGABRT, SIGSEGV, SIGBUS, SIGFPE] {
            _ = sigaction(sig, &action, nil)
        }
    }

    private static func handleFatalSignal(_ sig: Int32) {
        if signalCaptureEnabled != 0, let path = signalMarkerCPath {
            let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            if fd >= 0 {
                let (ptr, len): (UnsafePointer<CChar>?, Int) =
                    switch sig {
                    case SIGTRAP: (sigTrapMsg, 8)
                    case SIGILL: (sigIllMsg, 7)
                    case SIGABRT: (sigAbrtMsg, 8)
                    case SIGSEGV: (sigSegvMsg, 8)
                    case SIGBUS: (sigBusMsg, 7)
                    case SIGFPE: (sigFpeMsg, 7)
                    default: (nil, 0)
                    }
                if let ptr, len > 0 { _ = Darwin.write(fd, ptr, len) }
                _ = Darwin.close(fd)
            }
        }
        _ = Darwin.raise(sig)
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

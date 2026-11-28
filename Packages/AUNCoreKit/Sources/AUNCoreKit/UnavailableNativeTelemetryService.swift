import AUNCoreBridge
import Foundation
import Observation

/// Fail-closed fallback returned by ``CoreTelemetryService/live(environment:bundle:defaults:userAgentPrefix:bufferFilename:fixtures:)``
/// when native telemetry initialization fails. Never collects events, but still purges leftover
/// on-disk buffers and surfaces `lastPurgeFailed` so the UI can warn the user and offer a retry.
final class UnavailableNativeTelemetryService: TelemetryServicing, Observable, @unchecked Sendable {
    private let bufferPath: String?
    private let lock = NSLock()
    private let observationRegistrar = ObservationRegistrar()
    private var _lastPurgeFailed = false

    init(bufferPath: String?) {
        self.bufferPath = bufferPath
        _ = purgeBuffers()
    }

    var consent: TelemetryConsent { .off }
    var pendingCount: Int { 0 }

    var lastPurgeFailed: Bool {
        observationRegistrar.access(self, keyPath: \.lastPurgeFailed)
        return lock.withLock { _lastPurgeFailed }
    }

    @discardableResult
    func setConsent(_ consent: TelemetryConsent) -> Bool {
        guard consent == .off else { return false }
        return purgeBuffers()
    }

    private func purgeBuffers() -> Bool {
        let (purged, changed): (Bool, Bool) = lock.withLock {
            let ok = CoreTelemetryService.removeBufferAndTempFiles(at: bufferPath)
            let failed = !ok
            let didChange = _lastPurgeFailed != failed
            _lastPurgeFailed = failed
            return (ok, didChange)
        }
        if changed {
            observationRegistrar.willSet(self, keyPath: \.lastPurgeFailed)
            observationRegistrar.didSet(self, keyPath: \.lastPurgeFailed)
        }
        return purged
    }

    func track(_ name: String, properties: [String: String]) {}
    func trackError(_ code: String, properties: [String: String]) {}
    func addBreadcrumb(category: String, message: String, level: TelemetryBreadcrumbSeverity) {}
    func reportCrash(kind: String, message: String, stack: String?, fromPreviousSession: Bool) {}
    func persist() {}
    func flush() async {}
    func close() {}
}

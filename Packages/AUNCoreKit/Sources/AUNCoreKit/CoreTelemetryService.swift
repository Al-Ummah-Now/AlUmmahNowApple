import AUNCoreBridge
import AunCore
import Foundation

/// Wraps `aun-core`'s `TelemetryClient` behind ``TelemetryServicing``.
///
/// Privacy & safety invariants:
/// - Defaults to `.off` (silent: zero disk writes, zero network calls).
/// - Opting out immediately denies collection in the wrapper, cancels active flush waiters,
///   revokes native consent (even after `close()`), and purges memory + disk buffer + sibling `.tmp` files.
/// - Failed consent transitions fail closed in BOTH wrapper and native state.
/// - Ordinary `close()` preserves retryable persisted buffers; only explicit revocation removes remnants.
public final class CoreTelemetryService: TelemetryServicing, @unchecked Sendable {
    private let client: TelemetryClient
    private let bufferPath: String?
    private let isExternallyEnabled: (@Sendable () -> Bool)?
    private let lock = NSLock()

    private var _consent: TelemetryConsent = .off
    private var _revoked = false
    private var _closed = false
    private var _lastPurgeFailed = false
    private var _inFlightFlushes = 0
    private var _consentEpoch: UInt64 = 0
    private var _revokedFlushesRemaining = 0
    private var _flushWaiters: [UUID: Task<Void, Never>] = [:]

    /// Optional hook used by unit tests to inject a deterministic slow native flush.
    var flushOverrideForTesting: (@Sendable () async throws -> Void)?
    /// Optional hook run inside the queued flush task immediately before the pre-flush consent re-check.
    var beforeFlushExecuteForTesting: (@Sendable () -> Void)?

    public init(
        platform: String,
        appVersion: String,
        osVersion: String,
        deviceClass: String,
        locale: String,
        videosAPIBaseURL: URL?,
        userAgent: String,
        clientHeader: String = AUNClient.value,
        bufferPath: String?,
        initialEnabled: Bool = false,
        isExternallyEnabled: (@Sendable () -> Bool)? = nil
    ) throws {
        self.bufferPath = bufferPath
        self.isExternallyEnabled = isExternallyEnabled
        let app = TelemetryAppInfo(
            platform: platform, appVersion: appVersion, osVersion: osVersion,
            deviceClass: deviceClass, locale: locale
        )
        let config = TelemetryClientConfig(
            app: app, ingestUrl: Self.resolveIngestURL(videosAPIBaseURL),
            userAgent: userAgent, clientHeader: clientHeader,
            bufferPath: bufferPath, sampleRate: nil, maxBatchBytes: nil
        )
        self.client = try TelemetryClient(config: config)
        _ = setConsent(initialEnabled ? .full : .off)
    }

    public var consent: TelemetryConsent {
        lock.withLock { _closed ? .off : _consent }
    }

    public var pendingCount: Int {
        lock.withLock {
            guard !_closed, _consent != .off else { return 0 }
            return Int(client.pendingCount())
        }
    }

    public var lastPurgeFailed: Bool {
        lock.withLock { _lastPurgeFailed }
    }

    var nativeConsentForTesting: TelemetryConsentState {
        lock.withLock { client.consent() }
    }

    @discardableResult
    public func setConsent(_ consent: TelemetryConsent) -> Bool {
        let mapped: TelemetryConsentState = switch consent {
        case .full: .analytics
        case .crashOnly: .crashOnly
        case .off: .denied
        }

        let (result, waitersToCancel): (Bool, [Task<Void, Never>]) = lock.withLock {
            if _closed {
                if consent == .off {
                    return revokeLocked()
                }
                return (false, [])
            }
            if consent == .off {
                return revokeLocked()
            }
            if _revokedFlushesRemaining > 0 {
                return (false, [])
            }
            if _lastPurgeFailed {
                guard Self.removeBufferAndTempFiles(at: bufferPath) else {
                    return (false, [])
                }
                _lastPurgeFailed = false
            }
            do {
                try client.setConsent(consent: mapped)
                _consent = consent
                _revoked = false
                _lastPurgeFailed = false
                return (true, [])
            } catch {
                // Fail closed in BOTH wrapper and native state.
                let (_, waiters) = revokeLocked()
                AUNLog.network.warning("Failed to update telemetry consent; failing closed to off: \(error)")
                return (false, waiters)
            }
        }
        for waiter in waitersToCancel { waiter.cancel() }
        return result
    }

    public func track(_ name: String, properties: [String: String]) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let json = Self.serializeProperties(properties)
        withActiveConsent(requiresFull: true) {
            do { _ = try client.track(name: name, propertiesJson: json) } catch {
                AUNLog.network.warning("Telemetry track skipped: \(error)")
            }
        }
    }

    public func trackError(_ code: String, properties: [String: String]) {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let json = Self.serializeProperties(properties)
        withActiveConsent(requiresFull: true) {
            do { _ = try client.trackError(code: code, propertiesJson: json) } catch {
                AUNLog.network.warning("Telemetry error skipped: \(error)")
            }
        }
    }

    public func addBreadcrumb(category: String, message: String, level: TelemetryBreadcrumbSeverity) {
        guard !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let mapped: TelemetryBreadcrumbLevel = switch level {
        case .debug: .debug
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
        let safeMessage = Self.sanitizeLocalPaths(message)
        withActiveConsent(requiresFull: false) {
            client.addBreadcrumb(category: category, message: safeMessage, level: mapped)
        }
    }

    public func reportCrash(kind: String, message: String, stack: String?, fromPreviousSession: Bool) {
        let safeKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "UnhandledException" : kind
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeMessage = trimmed.isEmpty ? "Unhandled exception" : Self.sanitizeLocalPaths(trimmed)
        let report = TelemetryCrashReport(
            kind: safeKind, message: safeMessage,
            stack: stack.map(Self.sanitizeLocalPaths),
            occurredAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            fromPreviousSession: fromPreviousSession, propertiesJson: nil
        )
        withActiveConsent(requiresFull: false) {
            do {
                _ = try client.reportCrash(report: report)
                try client.persist()
            } catch {
                AUNLog.network.warning("Telemetry crash report skipped: \(error)")
            }
        }
    }

    public func persist() {
        withActiveConsent(requiresFull: false) {
            do { try client.persist() } catch {
                AUNLog.network.warning("Telemetry persist failed: \(error)")
            }
        }
    }

    public func flush() async {
        guard !Task.isCancelled else { return }
        let flushID = UUID()
        let override = flushOverrideForTesting
        let beforeExecute = beforeFlushExecuteForTesting
        let clientRef = client

        // Create AND register the flush task while holding `lock` so close() / setConsent(.off)
        // can never miss an unregistered task.
        let (nativeTask, cancelledWaiters): (Task<Void, Never>?, [Task<Void, Never>]) = lock.withLock {
            let cancelled = ensureExternalConsentLocked()
            guard !_closed, _consent != .off else { return (nil, cancelled) }
            _inFlightFlushes += 1
            let flushEpoch = _consentEpoch
            let task = Task<Void, Never> { [self] in
                defer { self.releaseInFlightFlush(id: flushID, epoch: flushEpoch) }
                beforeExecute?()
                let (stillAllowed, lateCancelled): (Bool, [Task<Void, Never>]) = self.lock.withLock {
                    let cancelledNow = self.ensureExternalConsentLocked()
                    let allowed = !self._closed && !self._revoked && self._consent != .off
                    return (allowed, cancelledNow)
                }
                for waiter in lateCancelled { waiter.cancel() }
                guard stillAllowed && !Task.isCancelled else { return }
                do {
                    if let override {
                        try await override()
                    } else {
                        _ = try await clientRef.flush()
                    }
                } catch {
                    let isRevoked = self.lock.withLock { self._revoked || self._closed }
                    if !isRevoked && !Task.isCancelled {
                        AUNLog.network.warning("Telemetry flush skipped: \(error)")
                    }
                }
            }
            _flushWaiters[flushID] = task
            return (task, cancelled)
        }
        for waiter in cancelledWaiters { waiter.cancel() }
        guard let nativeTask else { return }

        await withTaskCancellationHandler {
            await nativeTask.value
        } onCancel: {
            nativeTask.cancel()
        }
    }

    /// Stops new collection and cancels in-flight flush waits without revoking consent or deleting retryable buffers.
    public func close() {
        let waiters: [Task<Void, Never>] = lock.withLock {
            guard !_closed else { return [] }
            _closed = true
            _consent = .off
            let pending = Array(_flushWaiters.values)
            _flushWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.cancel() }
    }

    private func revokeLocked() -> (Bool, [Task<Void, Never>]) {
        _consent = .off
        _revoked = true
        _consentEpoch &+= 1
        _revokedFlushesRemaining = _inFlightFlushes
        let waiters = Array(_flushWaiters.values)
        _flushWaiters.removeAll()
        do {
            try client.setConsent(consent: .denied)
            _lastPurgeFailed = !Self.removeSiblingTempFiles(for: bufferPath)
        } catch {
            _lastPurgeFailed = !Self.removeBufferAndTempFiles(at: bufferPath)
            AUNLog.network.error("Telemetry disk purge failed on opt-out: \(error)")
        }
        return (!_lastPurgeFailed, waiters)
    }

    private func withActiveConsent(requiresFull: Bool, _ work: () -> Void) {
        let waiters = lock.withLock { () -> [Task<Void, Never>] in
            let cancelled = ensureExternalConsentLocked()
            let allowed = requiresFull ? (_consent == .full) : (_consent != .off)
            if !_closed && allowed { work() }
            return cancelled
        }
        for waiter in waiters { waiter.cancel() }
    }

    private func releaseInFlightFlush(id: UUID, epoch: UInt64) {
        lock.withLock {
            _flushWaiters.removeValue(forKey: id)
            _inFlightFlushes = max(0, _inFlightFlushes - 1)
            if epoch != _consentEpoch {
                _revokedFlushesRemaining = max(0, _revokedFlushesRemaining - 1)
                if bufferPath != nil {
                    _lastPurgeFailed = !Self.removeBufferAndTempFiles(at: bufferPath)
                }
            }
        }
    }

    private func ensureExternalConsentLocked() -> [Task<Void, Never>] {
        guard !_closed, _consent != .off, let check = isExternallyEnabled, !check() else { return [] }
        let (_, waiters) = revokeLocked()
        return waiters
    }
}

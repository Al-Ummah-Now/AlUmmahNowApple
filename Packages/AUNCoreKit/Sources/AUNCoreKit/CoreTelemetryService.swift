import AUNCoreBridge
import AunCore
import Foundation
import Observation

/// Wraps `aun-core`'s `TelemetryClient` behind ``TelemetryServicing``.
///
/// Privacy & safety invariants:
/// - Defaults to `.off` (silent: zero disk writes, zero network calls).
/// - Opting out immediately denies collection in the wrapper, cancels active flush waiters,
///   revokes native consent (even after `close()`), and purges memory + disk buffer + sibling `.tmp` files.
/// - Failed consent transitions fail closed in BOTH wrapper and native state.
/// - Ordinary `close()` preserves retryable persisted buffers; only explicit revocation removes remnants.
public final class CoreTelemetryService: TelemetryServicing, Observable, @unchecked Sendable {
    private let client: TelemetryClient
    private let bufferPath: String?
    private let isExternallyEnabled: (@Sendable () -> Bool)?
    private var defaultsObserver: NSObjectProtocol?
    private let lock = NSLock()
    private let observationRegistrar = ObservationRegistrar()

    private var _consent: TelemetryConsent = .off
    private var _revoked = false
    private var _closed = false
    private var _lastPurgeFailed = false
    private var _inFlightFlushes = 0
    private var _consentEpoch: UInt64 = 0
    private var _analyticsEpoch: UInt64 = 0
    private var _revokedFlushesRemaining = 0
    private var _flushWaiters: [UUID: Task<Void, Never>] = [:]

    /// Optional hook used by unit tests to inject a deterministic slow native flush.
    var flushOverrideForTesting: (@Sendable () async throws -> Void)?
    /// Optional hook run inside the queued flush task immediately before the pre-flush consent re-check.
    var beforeFlushExecuteForTesting: (@Sendable () -> Void)?
    /// Optional hook run right before committing a sanitized event/breadcrumb/crash under active consent.
    var beforeRecordCommitForTesting: (@Sendable () -> Void)?

    public convenience init(
        platform: String,
        appVersion: String,
        osVersion: String,
        deviceClass: String,
        locale: String,
        videosAPIBaseURL: URL?,
        userAgent: String,
        clientHeader: String = AUNClient.value,
        bufferPath: String?,
        initialEnabled: Bool = false
    ) throws {
        try self.init(
            platform: platform,
            appVersion: appVersion,
            osVersion: osVersion,
            deviceClass: deviceClass,
            locale: locale,
            videosAPIBaseURL: videosAPIBaseURL,
            userAgent: userAgent,
            clientHeader: clientHeader,
            bufferPath: bufferPath,
            initialEnabled: initialEnabled,
            isExternallyEnabled: nil,
            observedDefaults: nil,
            observedDefaultsKey: nil
        )
    }

    init(
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
        isExternallyEnabled: (@Sendable () -> Bool)?,
        observedDefaults: UserDefaults? = nil,
        observedDefaultsKey: String? = nil
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
        if let observedDefaults, let observedDefaultsKey {
            nonisolated(unsafe) let defaultsRef = observedDefaults
            self.defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                if !defaultsRef.bool(forKey: observedDefaultsKey) {
                    self?.revokeIfExternallyDisabled()
                }
            }
        }
        _ = setConsent(initialEnabled ? .full : .off)
        if initialEnabled, isExternallyEnabled != nil {
            revokeIfExternallyDisabled()
        }
    }

    deinit {
        if let obs = defaultsObserver { NotificationCenter.default.removeObserver(obs) }
    }

    public var consent: TelemetryConsent {
        observationRegistrar.access(self, keyPath: \.consent)
        return lock.withLock { _closed ? .off : _consent }
    }

    public var pendingCount: Int {
        lock.withLock {
            guard !_closed, _consent != .off else { return 0 }
            return Int(client.pendingCount())
        }
    }

    public var lastPurgeFailed: Bool {
        observationRegistrar.access(self, keyPath: \.lastPurgeFailed)
        return lock.withLock { _lastPurgeFailed }
    }

    var nativeConsentForTesting: TelemetryConsentState {
        lock.withLock { client.consent() }
    }

    @discardableResult
    public func setConsent(_ consent: TelemetryConsent) -> Bool {
        let mapped: TelemetryConsentState =
            switch consent {
            case .full: .analytics
            case .crashOnly: .crashOnly
            case .off: .denied
            }

        let (result, waitersToCancel, purgeChanged, consentChanged): (Bool, [Task<Void, Never>], Bool, Bool) = lock.withLock {
            let priorPurgeFailed = _lastPurgeFailed
            let priorConsent = _closed ? .off : _consent
            let outcome: (Bool, [Task<Void, Never>])
            if _closed {
                outcome = consent == .off ? revokeLocked() : (false, [])
            } else if consent == .off {
                outcome = revokeLocked()
            } else if _revokedFlushesRemaining > 0 {
                outcome = (false, [])
            } else if _lastPurgeFailed && !Self.removeBufferAndTempFiles(at: bufferPath) {
                outcome = (false, [])
            } else if let check = isExternallyEnabled, !check() {
                let (_, waiters) = revokeLocked()
                outcome = (false, waiters)
            } else {
                _lastPurgeFailed = false
                do {
                    try client.setConsent(consent: mapped)
                    if _consent == .full && consent != .full {
                        _analyticsEpoch &+= 1
                    }
                    _consent = consent
                    _revoked = false
                    _lastPurgeFailed = false
                    outcome = (true, [])
                } catch {
                    // Fail closed in BOTH wrapper and native state.
                    let (_, waiters) = revokeLocked()
                    AUNLog.network.warning("Failed to update telemetry consent; failing closed to off: \(error)")
                    outcome = (false, waiters)
                }
            }
            let currentConsent = _closed ? .off : _consent
            return (outcome.0, outcome.1, _lastPurgeFailed != priorPurgeFailed, currentConsent != priorConsent)
        }
        notifyStateChanges(purgeChanged: purgeChanged, consentChanged: consentChanged)
        for waiter in waitersToCancel { waiter.cancel() }
        return result
    }

    public func track(_ name: String, properties: [String: String]) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let captureEpoch = captureConsentEpoch(requiresFull: true)
        else { return }
        let safeName = Self.sanitizePropertyKey(name)
        guard !safeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let json = Self.serializeProperties(properties)
        beforeRecordCommitForTesting?()
        withActiveConsent(requiresFull: true, expectedEpoch: captureEpoch) {
            do { _ = try client.track(name: safeName, propertiesJson: json) } catch {
                AUNLog.network.warning("Telemetry track skipped: \(error)")
            }
        }
    }

    public func trackError(_ code: String, properties: [String: String]) {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let captureEpoch = captureConsentEpoch(requiresFull: true)
        else { return }
        let safeCode = Self.sanitizePropertyKey(code)
        guard !safeCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let json = Self.serializeProperties(properties)
        beforeRecordCommitForTesting?()
        withActiveConsent(requiresFull: true, expectedEpoch: captureEpoch) {
            do { _ = try client.trackError(code: safeCode, propertiesJson: json) } catch {
                AUNLog.network.warning("Telemetry error skipped: \(error)")
            }
        }
    }

    public func addBreadcrumb(category: String, message: String, level: TelemetryBreadcrumbSeverity) {
        guard !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let captureEpoch = captureConsentEpoch(requiresFull: false)
        else { return }
        let mapped: TelemetryBreadcrumbLevel =
            switch level {
            case .debug: .debug
            case .info: .info
            case .warning: .warning
            case .error: .error
            }
        let safeCategory = Self.sanitizePropertyKey(category)
        let safeMessage = Self.sanitizeDiagnosticText(message)
        beforeRecordCommitForTesting?()
        withActiveConsent(requiresFull: false, expectedEpoch: captureEpoch) {
            client.addBreadcrumb(category: safeCategory, message: safeMessage, level: mapped)
        }
    }

    public func reportCrash(kind: String, message: String, stack: String?, fromPreviousSession: Bool) {
        guard let captureEpoch = captureConsentEpoch(requiresFull: false) else { return }
        let trimmedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeKind = trimmedKind.isEmpty ? "UnhandledException" : Self.sanitizePropertyKey(trimmedKind)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeMessage = trimmed.isEmpty ? "Unhandled exception" : Self.sanitizeDiagnosticText(trimmed)
        let report = TelemetryCrashReport(
            kind: safeKind, message: safeMessage,
            stack: stack.map(Self.sanitizeDiagnosticText),
            occurredAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            fromPreviousSession: fromPreviousSession, propertiesJson: nil
        )
        beforeRecordCommitForTesting?()
        withActiveConsent(requiresFull: false, expectedEpoch: captureEpoch) {
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
        let (nativeTask, cancelledWaiters, purgeChanged, consentChanged): (Task<Void, Never>?, [Task<Void, Never>], Bool, Bool) =
            lock.withLock {
                let priorPurgeFailed = _lastPurgeFailed
                let priorConsent = _closed ? .off : _consent
                let cancelled = ensureExternalConsentLocked()
                guard !_closed, _consent != .off else {
                    let currentConsent = _closed ? .off : _consent
                    return (nil, cancelled, _lastPurgeFailed != priorPurgeFailed, currentConsent != priorConsent)
                }
                _inFlightFlushes += 1
                let flushEpoch = _consentEpoch
                let task = Task<Void, Never> { [self] in
                    defer { self.releaseInFlightFlush(id: flushID, epoch: flushEpoch) }
                    beforeExecute?()
                    let (stillAllowed, lateCancelled, latePurgeChanged, lateConsentChanged):
                        (Bool, [Task<Void, Never>], Bool, Bool) = self.lock.withLock {
                            let prior = self._lastPurgeFailed
                            let priorC = self._closed ? .off : self._consent
                            let cancelledNow = self.ensureExternalConsentLocked()
                            let allowed =
                                !self._closed && !self._revoked && self._consent != .off && self._consentEpoch == flushEpoch
                            let currentC = self._closed ? .off : self._consent
                            return (allowed, cancelledNow, self._lastPurgeFailed != prior, currentC != priorC)
                        }
                    self.notifyStateChanges(purgeChanged: latePurgeChanged, consentChanged: lateConsentChanged)
                    for waiter in lateCancelled { waiter.cancel() }
                    guard stillAllowed && !Task.isCancelled else { return }
                    let monitorTask = self.startExternalFlushMonitorIfNeeded()
                    defer { monitorTask?.cancel() }
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
                let currentConsent = _closed ? .off : _consent
                return (task, cancelled, _lastPurgeFailed != priorPurgeFailed, currentConsent != priorConsent)
            }
        notifyStateChanges(purgeChanged: purgeChanged, consentChanged: consentChanged)
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
        let (waiters, consentChanged): ([Task<Void, Never>], Bool) = lock.withLock {
            guard !_closed else { return ([], false) }
            let priorConsent = _consent
            _closed = true
            _consent = .off
            let pending = Array(_flushWaiters.values)
            _flushWaiters.removeAll()
            return (pending, priorConsent != .off)
        }
        notifyStateChanges(purgeChanged: false, consentChanged: consentChanged)
        for waiter in waiters { waiter.cancel() }
    }

    private func revokeLocked() -> (Bool, [Task<Void, Never>]) {
        _consent = .off
        _revoked = true
        _consentEpoch &+= 1
        _analyticsEpoch &+= 1
        _revokedFlushesRemaining = _inFlightFlushes
        let waiters = Array(_flushWaiters.values)
        _flushWaiters.removeAll()
        do {
            try client.setConsent(consent: .denied)
            _lastPurgeFailed = !Self.removeSiblingTempFiles(for: bufferPath)
        } catch {
            _ = Self.removeBufferAndTempFiles(at: bufferPath)
            _lastPurgeFailed = true
            AUNLog.network.error("Telemetry disk purge failed on opt-out: \(error)")
        }
        return (!_lastPurgeFailed, waiters)
    }

    private func captureConsentEpoch(requiresFull: Bool) -> UInt64? {
        let (epoch, waiters, purgeChanged, consentChanged): (UInt64?, [Task<Void, Never>], Bool, Bool) = lock.withLock {
            let priorPurgeFailed = _lastPurgeFailed
            let priorConsent = _closed ? .off : _consent
            let cancelled = ensureExternalConsentLocked()
            let allowed = !_closed && (requiresFull ? (_consent == .full) : (_consent != .off))
            let activeEpoch = requiresFull ? _analyticsEpoch : _consentEpoch
            let currentConsent = _closed ? .off : _consent
            return (
                allowed ? activeEpoch : nil, cancelled, _lastPurgeFailed != priorPurgeFailed,
                currentConsent != priorConsent
            )
        }
        notifyStateChanges(purgeChanged: purgeChanged, consentChanged: consentChanged)
        for waiter in waiters { waiter.cancel() }
        return epoch
    }

    private func withActiveConsent(requiresFull: Bool, expectedEpoch: UInt64? = nil, _ work: () -> Void) {
        let (waiters, purgeChanged, consentChanged): ([Task<Void, Never>], Bool, Bool) = lock.withLock {
            let priorPurgeFailed = _lastPurgeFailed
            let priorConsent = _closed ? .off : _consent
            let cancelled = ensureExternalConsentLocked()
            let activeEpoch = requiresFull ? _analyticsEpoch : _consentEpoch
            let epochMatches = expectedEpoch == nil || activeEpoch == expectedEpoch
            let allowed = (requiresFull ? (_consent == .full) : (_consent != .off)) && epochMatches
            if !_closed && allowed { work() }
            let currentConsent = _closed ? .off : _consent
            return (cancelled, _lastPurgeFailed != priorPurgeFailed, currentConsent != priorConsent)
        }
        notifyStateChanges(purgeChanged: purgeChanged, consentChanged: consentChanged)
        for waiter in waiters { waiter.cancel() }
    }

    private func releaseInFlightFlush(id: UUID, epoch: UInt64) {
        let purgeChanged: Bool = lock.withLock {
            let priorPurgeFailed = _lastPurgeFailed
            _flushWaiters.removeValue(forKey: id)
            _inFlightFlushes = max(0, _inFlightFlushes - 1)
            if epoch != _consentEpoch {
                _revokedFlushesRemaining = max(0, _revokedFlushesRemaining - 1)
                if bufferPath != nil {
                    let removed = Self.removeBufferAndTempFiles(at: bufferPath)
                    _lastPurgeFailed = _lastPurgeFailed || !removed
                }
            }
            return _lastPurgeFailed != priorPurgeFailed
        }
        notifyStateChanges(purgeChanged: purgeChanged, consentChanged: false)
    }

    private func notifyStateChanges(purgeChanged: Bool, consentChanged: Bool) {
        if purgeChanged {
            observationRegistrar.willSet(self, keyPath: \.lastPurgeFailed)
            observationRegistrar.didSet(self, keyPath: \.lastPurgeFailed)
        }
        if consentChanged {
            observationRegistrar.willSet(self, keyPath: \.consent)
            observationRegistrar.didSet(self, keyPath: \.consent)
        }
    }

    private func ensureExternalConsentLocked(allowWhenClosed: Bool = false) -> [Task<Void, Never>] {
        let shouldCheck = (!_closed && _consent != .off) || (allowWhenClosed && _closed && !_revoked)
        guard shouldCheck, let check = isExternallyEnabled, !check() else { return [] }
        let (_, waiters) = revokeLocked()
        return waiters
    }
}

extension CoreTelemetryService {
    func revokeIfExternallyDisabled() {
        let (cancelled, purgeChanged, consentChanged): ([Task<Void, Never>], Bool, Bool) = lock.withLock {
            let priorPurge = _lastPurgeFailed
            let priorConsent = _closed ? .off : _consent
            let waiters = ensureExternalConsentLocked(allowWhenClosed: true)
            let currentConsent = _closed ? .off : _consent
            return (waiters, _lastPurgeFailed != priorPurge, currentConsent != priorConsent)
        }
        notifyStateChanges(purgeChanged: purgeChanged, consentChanged: consentChanged)
        for waiter in cancelled { waiter.cancel() }
    }

    func startExternalFlushMonitorIfNeeded() -> Task<Void, Never>? {
        guard isExternallyEnabled != nil else { return nil }
        return Task<Void, Never> { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard !Task.isCancelled, let self else { return }
                self.revokeIfExternallyDisabled()
                let done = self.lock.withLock { self._revoked || (self._consent == .off && self._inFlightFlushes == 0) }
                if done { return }
            }
        }
    }
}

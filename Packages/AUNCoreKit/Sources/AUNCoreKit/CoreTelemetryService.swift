import AUNCoreBridge
import AunCore
import Foundation

/// Wraps `aun-core`'s `TelemetryClient` behind ``TelemetryServicing``.
///
/// Privacy & safety invariants:
/// - Defaults to `.off` (silent: zero disk writes, zero network calls).
/// - Opting out immediately denies collection in the wrapper, cancels active flush waiters,
///   revokes native consent, and purges memory + disk buffer (surfacing purge failures via ``lastPurgeFailed``).
/// - Failed consent transitions fail closed in BOTH wrapper and native state.
/// - Ordinary deallocation/shutdown does NOT delete a retryable buffer unless consent was revoked.
/// - Local filesystem paths and `file://` URIs are redacted from crash messages, stacks, and breadcrumbs.
/// - Ingest URLs are built strictly from HTTPS `host[:port]` (rejecting embedded credentials and stripping path/query/fragment).
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
    private var _flushWaiters: [UUID: Task<Void, Never>] = [:]

    /// Optional hook used by unit tests to inject a deterministic slow native flush.
    var flushOverrideForTesting: (@Sendable () async throws -> Void)?

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
            platform: platform,
            appVersion: appVersion,
            osVersion: osVersion,
            deviceClass: deviceClass,
            locale: locale
        )
        let config = TelemetryClientConfig(
            app: app,
            ingestUrl: Self.resolveIngestURL(videosAPIBaseURL),
            userAgent: userAgent,
            clientHeader: clientHeader,
            bufferPath: bufferPath,
            sampleRate: nil,
            maxBatchBytes: nil
        )
        self.client = try TelemetryClient(config: config)
        _ = setConsent(initialEnabled ? .full : .off)
    }

    /// Creates a live telemetry service for an Apple app, falling back to ``NullTelemetryService/shared``
    /// in fixture runs or if initialization fails.
    public static func live(
        environment: AppEnvironment,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        userAgentPrefix: String,
        bufferFilename: String = "telemetry-buffer.json",
        fixtures: Bool = false
    ) -> any TelemetryServicing {
        if fixtures { return NullTelemetryService.shared }
        let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let bundleID = bundle.bundleIdentifier ?? "net.alummahnow.apple"
        let locale = defaults.string(forKey: "AUNLanguage") ?? Locale.preferredLanguages.first ?? "en"
        let bufferURL = Self.defaultBufferURL(bundleID: bundleID, filename: bufferFilename)
        let osVersion = Self.osVersionString()
        let initialEnabled = defaults.bool(forKey: "AUNTelemetryEnabled")
        // Non-sendable UserDefaults is read via suite lookup / standard safely on demand.
        let suiteName = defaults === UserDefaults.standard ? nil : bundleID
        let externalCheck: @Sendable () -> Bool = {
            let store = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            return store.bool(forKey: "AUNTelemetryEnabled")
        }
        do {
            return try CoreTelemetryService(
                platform: Self.platformName(),
                appVersion: version,
                osVersion: osVersion,
                deviceClass: Self.deviceClassName(),
                locale: locale,
                videosAPIBaseURL: environment.apiBaseURL,
                userAgent: "\(userAgentPrefix)/\(version)",
                clientHeader: AUNClient.value,
                bufferPath: bufferURL?.path,
                initialEnabled: initialEnabled,
                isExternallyEnabled: externalCheck
            )
        } catch {
            AUNLog.network.error("Telemetry unavailable, continuing with no-op service: \(error)")
            return NullTelemetryService.shared
        }
    }

    /// Constructs `https://<host>[:<port>]/api/v1/telemetry/batches` from a parsed HTTPS URL,
    /// rejecting embedded credentials (`user`/`password`) and stripping any path, query, or fragment.
    /// Returns `nil` (no-op sink) for empty, non-HTTPS, or credential-bearing URLs.
    public static func resolveIngestURL(_ baseURL: URL?) -> String? {
        guard let baseURL else { return nil }
        return resolveIngestURL(baseURL.absoluteString)
    }

    public static func resolveIngestURL(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard let components = URLComponents(string: trimmed) else { return nil }
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard components.user == nil, components.password == nil else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let portSegment: String
        if let port = components.port, port != 443 {
            portSegment = ":\(port)"
        } else {
            portSegment = ""
        }
        return "https://\(formattedHost)\(portSegment)/api/v1/telemetry/batches"
    }

    /// Scrubs local filesystem paths and `file://` URIs before crash or breadcrumb text enters telemetry.
    public static func sanitizeLocalPaths(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for regex in Self.pathRegexes {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[redacted-path]")
        }
        return result
    }

    private static let pathRegexes: [NSRegularExpression] = {
        let patterns = [
            // Quoted file URIs, Windows drive/UNC paths, and Unix paths (arbitrary Unicode/spaces/symbols inside quotes)
            #"(["'])(?:file://|(?:[A-Za-z]:[\\/]|\\\\)|~/(?!\s)|/[^"'\r\n/]+/)[^"'\r\n]+\1"#,
            // Unquoted file:// URIs
            #"file://[^\r\n"'<>|;]+"#,
            // Unquoted Windows drive or UNC paths through end of clause (preserving :line N / :N in stack frames)
            #"(?:[A-Za-z]:[\\/]|\\\\)[^\r\n"'<>|;]+?(?=(?::line\b|:\d+\b|[\r\n"'<>|;]|$))"#,
            // Unquoted Unix ~/ or any multi-segment absolute path through end of clause (preserving :line N / :N)
            #"(?<![\p{L}\p{M}\p{N}._:/-])(?:~/|/[^\s/"'<>|;:\r\n]+/)[^\r\n"'<>|;]*?(?=(?::line\b|:\d+\b|[\r\n"'<>|;]|$))"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

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
                    _revoked = true
                    _lastPurgeFailed = !tryDeleteBufferFallback()
                    return (!_lastPurgeFailed, [])
                }
                return (false, [])
            }

            if consent == .off {
                _consent = .off
                _revoked = true
                let waiters = Array(_flushWaiters.values)
                _flushWaiters.removeAll()
                do {
                    try client.setConsent(consent: .denied)
                    _lastPurgeFailed = false
                } catch {
                    _lastPurgeFailed = !tryDeleteBufferFallback()
                    AUNLog.network.error("Telemetry disk purge failed on opt-out: \(error)")
                }
                return (!_lastPurgeFailed, waiters)
            }

            do {
                try client.setConsent(consent: mapped)
                _consent = consent
                _revoked = false
                _lastPurgeFailed = false
                return (true, [])
            } catch {
                // Fail closed in BOTH wrapper and native state so an earlier native transition
                // cannot leave collection active for a queued flush.
                _consent = .off
                _revoked = true
                let waiters = Array(_flushWaiters.values)
                _flushWaiters.removeAll()
                do {
                    try client.setConsent(consent: .denied)
                } catch {
                    _lastPurgeFailed = !tryDeleteBufferFallback()
                }
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
        let waiters = lock.withLock { () -> [Task<Void, Never>] in
            let cancelled = ensureExternalConsentLocked()
            guard !_closed, _consent == .full else { return cancelled }
            do {
                _ = try client.track(name: name, propertiesJson: json)
            } catch {
                AUNLog.network.warning("Telemetry track skipped: \(error)")
            }
            return cancelled
        }
        for waiter in waiters { waiter.cancel() }
    }

    public func trackError(_ code: String, properties: [String: String]) {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let json = Self.serializeProperties(properties)
        let waiters = lock.withLock { () -> [Task<Void, Never>] in
            let cancelled = ensureExternalConsentLocked()
            guard !_closed, _consent == .full else { return cancelled }
            do {
                _ = try client.trackError(code: code, propertiesJson: json)
            } catch {
                AUNLog.network.warning("Telemetry error skipped: \(error)")
            }
            return cancelled
        }
        for waiter in waiters { waiter.cancel() }
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
        let waiters = lock.withLock { () -> [Task<Void, Never>] in
            let cancelled = ensureExternalConsentLocked()
            guard !_closed, _consent != .off else { return cancelled }
            client.addBreadcrumb(category: category, message: safeMessage, level: mapped)
            return cancelled
        }
        for waiter in waiters { waiter.cancel() }
    }

    public func reportCrash(kind: String, message: String, stack: String?, fromPreviousSession: Bool) {
        let safeKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "UnhandledException" : kind
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeMessage = trimmedMessage.isEmpty ? "Unhandled exception" : Self.sanitizeLocalPaths(trimmedMessage)
        let safeStack = stack.map(Self.sanitizeLocalPaths)
        let report = TelemetryCrashReport(
            kind: safeKind,
            message: safeMessage,
            stack: safeStack,
            occurredAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            fromPreviousSession: fromPreviousSession,
            propertiesJson: nil
        )
        let waiters = lock.withLock { () -> [Task<Void, Never>] in
            let cancelled = ensureExternalConsentLocked()
            guard !_closed, _consent != .off else { return cancelled }
            do {
                _ = try client.reportCrash(report: report)
                try client.persist()
            } catch {
                AUNLog.network.warning("Telemetry crash report skipped: \(error)")
            }
            return cancelled
        }
        for waiter in waiters { waiter.cancel() }
    }

    public func persist() {
        let waiters = lock.withLock { () -> [Task<Void, Never>] in
            let cancelled = ensureExternalConsentLocked()
            guard !_closed, _consent != .off else { return cancelled }
            do {
                try client.persist()
            } catch {
                AUNLog.network.warning("Telemetry persist failed: \(error)")
            }
            return cancelled
        }
        for waiter in waiters { waiter.cancel() }
    }

    public func flush() async {
        guard !Task.isCancelled else { return }

        let flushID = UUID()
        let (shouldRun, cancelledWaiters): (Bool, [Task<Void, Never>]) = lock.withLock {
            let cancelled = ensureExternalConsentLocked()
            guard !_closed, _consent != .off else { return (false, cancelled) }
            _inFlightFlushes += 1
            return (true, cancelled)
        }
        for waiter in cancelledWaiters { waiter.cancel() }
        guard shouldRun else { return }

        let override = flushOverrideForTesting
        let clientRef = client
        let nativeTask = Task<Void, Never> { [self] in
            defer { self.releaseInFlightFlush(id: flushID) }
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

        let registered: Bool = lock.withLock {
            if _closed || _consent == .off {
                return false
            }
            _flushWaiters[flushID] = nativeTask
            return true
        }
        if !registered {
            nativeTask.cancel()
            return
        }

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
            let w = Array(_flushWaiters.values)
            _flushWaiters.removeAll()
            return w
        }
        for waiter in waiters { waiter.cancel() }
    }

    private func releaseInFlightFlush(id: UUID) {
        lock.withLock {
            _flushWaiters.removeValue(forKey: id)
            _inFlightFlushes = max(0, _inFlightFlushes - 1)
            if _revoked, bufferPath != nil {
                // Clean up any remnant if a flush already in flight before revocation finished its
                // final persist rename after setConsent(.denied) removed the buffer file.
                // Ordinary close() without revocation does NOT set _revoked, preserving retryable buffers.
                if !tryDeleteBufferFallback() {
                    _lastPurgeFailed = true
                }
            }
        }
    }

    private func ensureExternalConsentLocked() -> [Task<Void, Never>] {
        guard !_closed, _consent != .off, let check = isExternallyEnabled else { return [] }
        guard !check() else { return [] }
        _consent = .off
        _revoked = true
        let waiters = Array(_flushWaiters.values)
        _flushWaiters.removeAll()
        do {
            try client.setConsent(consent: .denied)
            _lastPurgeFailed = false
        } catch {
            _lastPurgeFailed = !tryDeleteBufferFallback()
            AUNLog.network.error("Telemetry disk purge failed after external opt-out: \(error)")
        }
        return waiters
    }

    private func tryDeleteBufferFallback() -> Bool {
        guard let bufferPath, !bufferPath.isEmpty else { return true }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: bufferPath, isDirectory: &isDir) else { return true }
        if isDir.boolValue { return false }
        do {
            try fm.removeItem(atPath: bufferPath)
            return true
        } catch {
            return false
        }
    }

    static func serializeProperties(_ properties: [String: String]) -> String? {
        guard !properties.isEmpty else { return nil }
        let filtered = properties.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !filtered.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    private static func defaultBufferURL(bundleID: String, filename: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent(filename, isDirectory: false)
    }

    private static func platformName() -> String {
        #if os(macOS)
            "macos"
        #elseif os(tvOS)
            "tvos"
        #else
            "ios"
        #endif
    }

    private static func deviceClassName() -> String {
        #if os(macOS)
            "desktop"
        #elseif os(tvOS)
            "tv"
        #else
            var info = utsname()
            uname(&info)
            let machine = withUnsafeBytes(of: &info.machine) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) ?? "" }
            return machine.hasPrefix("iPad") ? "tablet" : "phone"
        #endif
    }

    private static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
            return "macOS \(v.majorVersion).\(v.minorVersion)"
        #elseif os(tvOS)
            return "tvOS \(v.majorVersion).\(v.minorVersion)"
        #else
            return "iOS \(v.majorVersion).\(v.minorVersion)"
        #endif
    }
}

/// Process-wide uncaught NSException bridge (chaining any previously installed handler).
public enum CrashTelemetryHook {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var installed = false
    private nonisolated(unsafe) static var activeService: (any TelemetryServicing)?
    private nonisolated(unsafe) static var previousHandler: (@convention(c) (NSException) -> Void)?

    public static func install(service: any TelemetryServicing) {
        lock.withLock {
            activeService = service
            guard !installed else { return }
            installed = true
            previousHandler = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { exception in
                CrashTelemetryHook.handle(exception)
            }
        }
    }

    private static func handle(_ exception: NSException) {
        let (service, previous) = lock.withLock { (activeService, previousHandler) }
        service?.reportCrash(
            kind: exception.name.rawValue,
            message: exception.reason ?? "Uncaught NSException",
            stack: exception.callStackSymbols.joined(separator: "\n"),
            fromPreviousSession: false
        )
        previous?(exception)
    }
}

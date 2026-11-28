import AUNCoreBridge
import AunCore
import Foundation

/// ``TelemetryServicing`` on aun-core's `TelemetryClient`. The core scrubs every string (e-mails, tokens,
/// URL queries, long secrets), keeps the buffer file, purges it when consent is withdrawn and posts batches
/// to the videos API's `/api/v1/telemetry/batches`. This class maps consent, hands it crashes and asks it
/// to flush. Every call is guarded: reporting must never cause a failure.
public final class CoreTelemetryService: TelemetryServicing, @unchecked Sendable {
    private let client: TelemetryClient

    init(client: TelemetryClient) {
        self.client = client
    }

    /// The app's telemetry, or ``NullTelemetryService/shared`` in fixture runs or where the core can't start.
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
        let bufferURL = defaultBufferURL(bundleID: bundleID, filename: bufferFilename)
        if let folder = bufferURL?.deletingLastPathComponent() {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        do {
            let client = try TelemetryClient(
                config: TelemetryClientConfig(
                    app: TelemetryAppInfo(
                        platform: platformName(),
                        appVersion: version,
                        osVersion: osVersionString(),
                        deviceClass: deviceClassName(),
                        locale: locale
                    ),
                    ingestUrl: resolveIngestURL(environment.apiBaseURL),
                    userAgent: "\(userAgentPrefix)/\(version)",
                    clientHeader: AUNClient.value,
                    bufferPath: bufferURL?.path,
                    sampleRate: nil,
                    maxBatchBytes: nil
                ))
            let service = CoreTelemetryService(client: client)
            service.setConsent(defaults.bool(forKey: "AUNTelemetryEnabled") ? .full : .off)
            return service
        } catch {
            AUNLog.network.error("Telemetry unavailable, continuing with no-op service: \(error)")
            return NullTelemetryService.shared
        }
    }

    public var consent: TelemetryConsent {
        switch client.consent() {
        case .analytics: .full
        case .crashOnly: .crashOnly
        default: .off
        }
    }

    @discardableResult
    public func setConsent(_ consent: TelemetryConsent) -> Bool {
        let state: TelemetryConsentState =
            switch consent {
            case .full: .analytics
            case .crashOnly: .crashOnly
            case .off: .denied
            }
        do {
            try client.setConsent(consent: state)
            return true
        } catch {
            AUNLog.network.error("Telemetry consent change failed: \(error)")
            return false
        }
    }

    public func reportCrash(kind: String, message: String, stack: String?) {
        let report = TelemetryCrashReport(
            kind: kind,
            message: message,
            stack: stack,
            occurredAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            fromPreviousSession: false,
            propertiesJson: nil
        )
        _ = try? client.reportCrash(report: report)
        try? client.persist()
    }

    public func persist() {
        try? client.persist()
    }

    public func flush() async {
        // Offline or refused: the core keeps the batch for the next flush.
        _ = try? await client.flush()
    }

    /// `https://<host>[:<port>]/api/v1/telemetry/batches` from an https videos API; `nil` (nothing is sent)
    /// for anything else, including local http dev servers and URLs with credentials.
    public static func resolveIngestURL(_ baseURL: URL?) -> String? {
        guard let baseURL else { return nil }
        return resolveIngestURL(baseURL.absoluteString)
    }

    public static func resolveIngestURL(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
            let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "https",
            components.user == nil, components.password == nil,
            let host = components.host, !host.isEmpty
        else { return nil }
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let portSegment = components.port.map { $0 == 443 ? "" : ":\($0)" } ?? ""
        return "https://\(formattedHost)\(portSegment)/api/v1/telemetry/batches"
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

/// Records uncaught Objective-C exceptions, then hands them to the handler that was there before.
public enum CrashTelemetryHook {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var activeService: (any TelemetryServicing)?
    private nonisolated(unsafe) static var previousHandler: (@convention(c) (NSException) -> Void)?

    public static func install(service: any TelemetryServicing) {
        lock.withLock {
            let first = activeService == nil
            activeService = service
            guard first else { return }
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
            stack: exception.callStackSymbols.joined(separator: "\n")
        )
        previous?(exception)
    }
}

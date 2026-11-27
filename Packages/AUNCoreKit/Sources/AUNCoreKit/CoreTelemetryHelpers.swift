import AUNCoreBridge
import AunCore
import Foundation

extension CoreTelemetryService {
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
        let portSegment = if let port = components.port, port != 443 { ":\(port)" } else { "" }
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
            // Double-quoted paths (may contain apostrophes, semicolons, spaces, Unicode, or parentheses)
            #""(?:file://|(?:[A-Za-z]:[\\/]|\\\\)|~/(?!\s)|/(?=[^\s/"]))[^"\r\n]*""#,
            // Unquoted file:// URIs
            #"file://[^\r\n"<>|]+"#,
            // Unquoted Windows drive or UNC paths through end of clause (preserving trailing :line N / :N in stacks)
            #"(?:[A-Za-z]:[\\/]|\\\\)[^\r\n"<>|]+?(?=(?::line\s+\d+|:\d+(?::\d+)?)[)\]]*(?=\r|\n|$)|[\r\n"<>|]|$)"#,
            // Unquoted Unix ~/ or root paths (including single-segment, punctuation-prefixed, and colon/semicolon filenames)
            #"(?<![\p{L}\p{M}\p{N}._:/-])(?:~/|/(?=[^\s/"<>|]))[^\r\n"<>|]+?(?=(?::line\s+\d+|:\d+(?::\d+)?)[)\]]*(?=\r|\n|$)|[\r\n"<>|]|$)"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    static func serializeProperties(_ properties: [String: String]) -> String? {
        guard !properties.isEmpty else { return nil }
        let filtered = properties.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !filtered.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    static func removeBufferAndTempFiles(at bufferPath: String?) -> Bool {
        guard let bufferPath, !bufferPath.isEmpty else { return true }
        let mainOk = removeSingleFile(atPath: bufferPath)
        let tempsOk = removeSiblingTempFiles(for: bufferPath)
        return mainOk && tempsOk
    }

    static func removeSiblingTempFiles(for bufferPath: String?) -> Bool {
        guard let bufferPath, !bufferPath.isEmpty else { return true }
        let url = URL(fileURLWithPath: bufferPath)
        let dir = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent)."
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: dir.path)
        } catch let error as NSError where isNoSuchFile(error) {
            return true
        } catch {
            return false
        }
        var allRemoved = true
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(".tmp") {
            let fullPath = dir.appendingPathComponent(entry).path
            if !removeSingleFile(atPath: fullPath) {
                allRemoved = false
            }
        }
        return allRemoved
    }

    private static func removeSingleFile(atPath path: String) -> Bool {
        // Attempt direct unlink without a fileExists pre-check (which returns false on EACCES).
        if unlink(path) == 0 { return true }
        return errno == ENOENT
    }

    private static func isNoSuchFile(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
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

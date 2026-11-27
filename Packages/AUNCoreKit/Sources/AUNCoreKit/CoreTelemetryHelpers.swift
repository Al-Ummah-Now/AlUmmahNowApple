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
        nonisolated(unsafe) let defaultsStore = defaults
        let externalCheck: @Sendable () -> Bool = {
            defaultsStore.bool(forKey: "AUNTelemetryEnabled")
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

    /// Scrubs local filesystem paths, relative paths, bare filenames, and `file://` URIs while
    /// preserving valid non-`file` RFC 3986 URLs and stack symbols.
    public static func sanitizeLocalPaths(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var prefix = "\u{001E}AUNURL"
        while text.contains(prefix) {
            prefix += "X"
        }
        var (scrubbed, vaultedURLs) = Self.vaultNonFileURLs(in: text, prefix: prefix)
        for rule in Self.pathRedactionRules {
            let range = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
            scrubbed = rule.regex.stringByReplacingMatches(in: scrubbed, options: [], range: range, withTemplate: rule.template)
        }
        for (idx, original) in vaultedURLs.enumerated() {
            scrubbed = scrubbed.replacingOccurrences(of: "\(prefix)\(idx)\u{001F}", with: original)
        }
        for rule in Self.postRestoreRedactionRules {
            let range = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
            scrubbed = rule.regex.stringByReplacingMatches(in: scrubbed, options: [], range: range, withTemplate: rule.template)
        }
        return scrubbed
    }

    private static func vaultNonFileURLs(in text: String, prefix: String) -> (String, [String]) {
        guard let urlRegex = Self.urlVaultRegex else { return (text, []) }
        let nsText = text as NSString
        let matches = urlRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        var vaultedURLs: [String] = []
        var rebuilt = ""
        var cursor = 0
        for match in matches {
            let raw = nsText.substring(with: match.range)
            if raw.lowercased().hasPrefix("file://") { continue }
            let ipv6Range = match.range(at: 2)
            if ipv6Range.location != NSNotFound && !Self.isValidIPv6(nsText.substring(with: ipv6Range)) {
                continue
            }
            let baseURL = nsText.substring(with: match.range(at: 1))
            let qfRange = match.range(at: 3)
            let (url, tail): (String, String)
            if qfRange.location != NSNotFound && qfRange.length > 0 {
                let qf = nsText.substring(with: qfRange)
                let (cleanQF, trimmedTail) = Self.trimQueryOrFragmentDelimiters(
                    qf, nsText: nsText, matchStart: match.range.location)
                let marker = cleanQF.first.map(String.init) ?? "?"
                url = "\(baseURL)\(marker)[redacted]"
                tail = trimmedTail
            } else {
                (url, tail) = Self.trimTrailingURLDelimiters(baseURL, nsText: nsText, matchStart: match.range.location)
            }
            rebuilt += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let idx = vaultedURLs.count
            vaultedURLs.append(url)
            rebuilt += "\(prefix)\(idx)\u{001F}\(tail)"
            cursor = match.range.location + match.range.length
        }
        guard !vaultedURLs.isEmpty else { return (text, []) }
        rebuilt += nsText.substring(from: cursor)
        return (rebuilt, vaultedURLs)
    }

    private static func trimTrailingURLDelimiters(_ raw: String, nsText: NSString, matchStart: Int) -> (String, String) {
        var url = raw
        var tail = ""
        if url.hasSuffix(";") {
            url.removeLast()
            tail = ";"
        }
        if matchStart > 0 && nsText.character(at: matchStart - 1) == 0x27 && url.hasSuffix("'") {
            url.removeLast()
            tail = "'" + tail
        }
        return (url, tail)
    }

    private static func trimQueryOrFragmentDelimiters(_ qf: String, nsText: NSString, matchStart: Int) -> (String, String) {
        var value = qf
        var tail = ""
        while value.count > 1, let last = value.last {
            if last == ";" || last == "," {
                value.removeLast()
                tail = "\(last)\(tail)"
            } else if last == "'" && matchStart > 0 && nsText.character(at: matchStart - 1) == 0x27 {
                value.removeLast()
                tail = "'\(tail)"
            } else if last == ")" && value.filter({ $0 == ")" }).count > value.filter({ $0 == "(" }).count {
                value.removeLast()
                tail = ")\(tail)"
            } else if last == "]" && value.filter({ $0 == "]" }).count > value.filter({ $0 == "[" }).count {
                value.removeLast()
                tail = "]\(tail)"
            } else {
                break
            }
        }
        return (value, tail)
    }

    private static func isValidIPv6(_ host: String) -> Bool {
        var addr = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }

    private static let urlVaultRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern:
            #"(?<![A-Za-z0-9+.-/\\])([A-Za-z][A-Za-z0-9+.-]+://(?:\[([^\]\s"'<>\\{}\r\n]+)\]|"#
            + #"(?:[A-Za-z0-9._~!$&'*+;=-]|%[0-9A-Fa-f]{2})+)(?::\d+)?"#
            + #"(?:/(?:(?!(?:file://|[A-Za-z]:[\\/]))(?:[^\s"<>\\{},()\[\]?#\r\n]|"#
            + #"\([^\s"<>\\{},()\[\]/:\\?#]+\)|\[[^\s"<>\\{},()\[\]/:\\?#]+\]))*)?)"#
            + #"([?#][^\s"<>\\{}\r\n]*)?(?=$|[\s"'<>\\{},;()\[\]]|file://|[A-Za-z]:[\\/])"#,
        options: [.caseInsensitive]
    )

    private static let bareFilenameExtensions =
        "mov|mp4|m4v|mkv|webm|avi|ts|m3u8|mpd|mp3|m4a|wav|aac|flac|ogg|opus|"
        + "jpg|jpeg|png|gif|webp|heic|svg|pdf|txt|md|rtf|doc|docx|xls|xlsx|ppt|pptx|"
        + "csv|json|xml|yaml|yml|toml|ini|cfg|conf|log|srt|vtt|ass|ssa|"
        + "zip|tar|gz|tgz|bz2|xz|7z|rar|dmg|pkg|msi|exe|apk|aab|ipa|"
        + "pem|key|crt|cer|p12|pfx|jks|keystore|db|sqlite|sqlite3|bin|dat|tmp|bak|proj|aun"

    private static let ioKeywordVerbs =
        "open|opening|read|reading|write|writing|delete|deleting|remove|removing|rename|stat|"
        + "create|creating|load|loading|save|saving|access|accessing|unlink|"
        + "file|path|directory|folder|document|filename|filepath"

    private static let sourceLineExts = "kt|java|swift|cs|cpp|cc|c|h|hpp|rs|py|js|ts|go|rb|m|mm"

    private static let pathRedactionRules: [(regex: NSRegularExpression, template: String)] = {
        let specs: [(String, String)] = [
            (#"(?<![A-Za-z0-9+.-])file://(?:(?!\s+\u001E)[^\r\n\u001E])+"#, "[redacted-path]"),
            (#"(\()(?:/|~/|[A-Za-z]:[\\/]|\\\\)[^()\r\n\u001E]+(\))"#, "$1[redacted-path]$2"),
            (
                #"(\()(?!HTTP/\d)(?!TLS/\d)(?!SSL/\d)[^\s/\\"'<>()\[\]{}:,;\u001E\u001F]+/[^()\r\n\u001E]+(\))"#,
                "$1[redacted-path]$2"
            ),
            (#"(?:[A-Za-z]:[\\/]|\\\\)(?:(?!\s+\u001E)[^\r\n\u001E])+"#, "[redacted-path]"),
            (
                #"(^|[\s(\[{"'=,:;\u001F])[^\s\\/"'<>(),;\u001E\u001F]+\\(?:(?!\s+\u001E)[^\r\n\u001E\u001F])+"#,
                "$1[redacted-path]"
            ),
            (#"["']/[ \t]+[^\r\n\u001E]+"#, "[redacted-path]"),
            (
                #"(?<![\p{L}\p{M}\p{N}._/-])(?:~/|//+(?=[ \t]*[^\s/])|/(?=[ \t]*[^\s/]))(?:(?!\s+\u001E)[^\r\n\u001E])+"#,
                "[redacted-path]"
            ),
            (
                #"(^|[\s(\[{"'=,:;\u001F])(?!HTTP/\d)(?!TLS/\d)(?!SSL/\d)[^\s/\\"'<>()\[\]{}:,;\u001E\u001F]+/(?:(?!\s+\u001E)[^\r\n\u001E\u001F])+"#,
                "$1[redacted-path]"
            ),
            (#""[^"\r\n/\\]*\.[A-Za-z0-9]{1,16}""#, "[redacted-path]"),
            (#"'(?:[^'\r\n/\\]|'(?=\p{L}))*\.[A-Za-z0-9]{1,16}'"#, "[redacted-path]"),
            (#"(\b(?:file|path|directory|folder|document)\s+)(['"])(?!\u001E)[^'"\r\n]+\2"#, "$1[redacted-path]"),
            (
                #"(\b(?:"# + ioKeywordVerbs + #")\b(?:\s*[:=]\s*|\s+))(?!\u001E)[^\r\n\u001E\u001F]*\.(?!(?:"#
                    + sourceLineExts + #"):\d+)[A-Za-z0-9]{1,16}\b(?!\()"#,
                "$1[redacted-path]"
            ),
            (#"(\b(?:file|path|filename|filepath)\s*[:=]\s*)(?!\u001E)[^\r\n\u001E\u001F]+"#, "$1[redacted-path]"),
            (
                #"(^|[\r\n:=;\u001F])([ \t]*)[^\r\n:=;\u001E\u001F]*\.(?!ts:\d+)(?:"# + bareFilenameExtensions + #")\b(?!\()"#,
                "$1$2[redacted-path]"
            ),
        ]
        return specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, template)
        }
    }()

    private static let postRestoreRedactionRules: [(regex: NSRegularExpression, template: String)] = {
        let specs: [(String, String)] = [
            (#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, "[redacted-email]"),
            (#"\bBearer\s+\S+"#, "Bearer [redacted]"),
        ]
        return specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, template)
        }
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

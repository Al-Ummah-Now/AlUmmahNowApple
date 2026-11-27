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
        scrubbed = Self.redactFileURIs(in: scrubbed, vaultPrefix: prefix)
        for rule in Self.pathRedactionRules {
            let range = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
            scrubbed = rule.regex.stringByReplacingMatches(in: scrubbed, options: [], range: range, withTemplate: rule.template)
        }
        scrubbed = Self.restoreVaultedURLs(in: scrubbed, prefix: prefix, vaultedURLs: vaultedURLs)
        for rule in Self.postRestoreRedactionRules {
            let range = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
            scrubbed = rule.regex.stringByReplacingMatches(in: scrubbed, options: [], range: range, withTemplate: rule.template)
        }
        return scrubbed
    }

    private struct VaultLineTracker {
        private var cursor = 0
        private var hasFileURIOnLine = false
        private var fileURIQuote: unichar = 0
        private var lastNonWSOrWrapperChar: unichar = 0
        private var tokenHasPathSep = false
        private var inWrapperRun = false
        private var wsBeforeRun = false

        mutating func isEmbeddedInPath(_ nsText: NSString, matchStart: Int) -> Bool {
            advance(nsText, to: matchStart)
            let afterPathSep = Self.isPathSep(lastNonWSOrWrapperChar)
            return fileURIQuote != 0
                || tokenHasPathSep
                || (!wsBeforeRun && hasFileURIOnLine)
                || (hasFileURIOnLine && inWrapperRun && afterPathSep)
        }

        mutating func onVaultedURL(matchEnd: Int) {
            cursor = matchEnd
            hasFileURIOnLine = false
            fileURIQuote = 0
            lastNonWSOrWrapperChar = 0
            tokenHasPathSep = false
            inWrapperRun = false
            wsBeforeRun = false
        }

        private mutating func advance(_ nsText: NSString, to target: Int) {
            while cursor < target {
                let ch = nsText.character(at: cursor)
                if ch == 0x0A || ch == 0x0D {
                    hasFileURIOnLine = false
                    fileURIQuote = 0
                    lastNonWSOrWrapperChar = 0
                    tokenHasPathSep = false
                    inWrapperRun = false
                    wsBeforeRun = false
                } else {
                    processLineChar(nsText, ch: ch)
                }
                cursor += 1
            }
        }

        private mutating func processLineChar(_ nsText: NSString, ch: unichar) {
            let closedFileQuote = fileURIQuote != 0 && ch == fileURIQuote
            if closedFileQuote {
                fileURIQuote = 0
            } else if Self.isFileScheme(nsText, at: cursor) {
                hasFileURIOnLine = true
                if cursor > 0 {
                    let prev = nsText.character(at: cursor - 1)
                    if prev == 0x22 || prev == 0x27 { fileURIQuote = prev }
                }
            }
            if closedFileQuote {
                lastNonWSOrWrapperChar = ch
                inWrapperRun = false
                wsBeforeRun = false
            } else if Self.isWhitespace(ch) {
                if !inWrapperRun {
                    wsBeforeRun = true
                    tokenHasPathSep = false
                }
            } else if Self.isOpeningWrapper(ch) {
                inWrapperRun = true
            } else {
                lastNonWSOrWrapperChar = ch
                if Self.isPathSep(ch) { tokenHasPathSep = true }
                inWrapperRun = false
                wsBeforeRun = false
            }
        }

        static func isFileScheme(_ nsText: NSString, at pos: Int) -> Bool {
            guard pos + 7 <= nsText.length else { return false }
            if pos > 0 && isURLSchemeChar(nsText.character(at: pos - 1)) { return false }
            let target: [unichar] = [0x66, 0x69, 0x6C, 0x65, 0x3A, 0x2F, 0x2F]  // "file://"
            for offset in 0..<7 {
                let raw = nsText.character(at: pos + offset)
                let folded = (raw >= 0x41 && raw <= 0x5A) ? (raw + 0x20) : raw
                if folded != target[offset] { return false }
            }
            return true
        }

        static func isURLSchemeChar(_ ch: unichar) -> Bool {
            (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)
                || (ch >= 0x30 && ch <= 0x39) || ch == 0x2B || ch == 0x2E || ch == 0x2D
        }

        static func isWhitespace(_ ch: unichar) -> Bool {
            if ch < 0x80 {
                return ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0x0B || ch == 0x0C
            }
            return UnicodeScalar(ch).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }

        static func isOpeningWrapper(_ ch: unichar) -> Bool {
            ch == 0x28 || ch == 0x5B || ch == 0x7B || ch == 0x22 || ch == 0x27
        }

        static func isPathSep(_ ch: unichar) -> Bool {
            ch == 0x2F || ch == 0x5C
        }
    }

    private static func matchesPrefix(_ nsText: NSString, at pos: Int, prefix: NSString) -> Bool {
        let len = prefix.length
        guard pos + len <= nsText.length else { return false }
        for offset in 0..<len where nsText.character(at: pos + offset) != prefix.character(at: offset) {
            return false
        }
        return true
    }

    private static func fileURISpanEnd(
        _ nsText: NSString, after schemeEnd: Int, vaultPrefix: NSString
    ) -> (rawEnd: Int, trimmedEnd: Int) {
        let totalLength = nsText.length
        var rawEnd = schemeEnd
        var stoppedAtVault = false
        while rawEnd < totalLength {
            let ch = nsText.character(at: rawEnd)
            if ch == 0x0A || ch == 0x0D { break }
            if ch == 0x1E && matchesPrefix(nsText, at: rawEnd, prefix: vaultPrefix) {
                stoppedAtVault = true
                break
            }
            rawEnd += 1
        }
        guard stoppedAtVault else { return (rawEnd, rawEnd) }
        var trimmedEnd = rawEnd
        while trimmedEnd > schemeEnd {
            let prev = nsText.character(at: trimmedEnd - 1)
            if VaultLineTracker.isOpeningWrapper(prev) || VaultLineTracker.isWhitespace(prev) {
                trimmedEnd -= 1
            } else {
                break
            }
        }
        return (rawEnd, trimmedEnd)
    }

    private static func redactFileURIs(in text: String, vaultPrefix: String) -> String {
        let nsText = text as NSString
        let nsPrefix = vaultPrefix as NSString
        let totalLength = nsText.length
        guard totalLength >= 7 else { return text }
        var result = ""
        var copyStart = 0
        var pos = 0
        while pos < totalLength {
            if VaultLineTracker.isFileScheme(nsText, at: pos) {
                let (rawEnd, trimmedEnd) = fileURISpanEnd(nsText, after: pos + 7, vaultPrefix: nsPrefix)
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copyStart, length: pos - copyStart))
                result += "[redacted-path]"
                result += nsText.substring(with: NSRange(location: trimmedEnd, length: rawEnd - trimmedEnd))
                copyStart = rawEnd
                pos = rawEnd
                continue
            }
            pos += 1
        }
        guard copyStart > 0 else { return text }
        result += nsText.substring(from: copyStart)
        return result
    }

    private static func vaultNonFileURLs(in text: String, prefix: String) -> (String, [String]) {
        guard let urlRegex = Self.urlVaultRegex else { return (text, []) }
        let nsText = text as NSString
        let matches = urlRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        var vaultedURLs: [String] = []
        var tracker = VaultLineTracker()
        var rebuilt = ""
        var cursor = 0
        for match in matches {
            let raw = nsText.substring(with: match.range)
            let embedded = tracker.isEmbeddedInPath(nsText, matchStart: match.range.location)
            if raw.lowercased().hasPrefix("file://") || embedded {
                continue
            }
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
            tracker.onVaultedURL(matchEnd: match.range.location + match.range.length)
            rebuilt += "\(prefix)\(idx)\u{001F}\(tail)"
            cursor = match.range.location + match.range.length
        }
        guard !vaultedURLs.isEmpty else { return (text, []) }
        rebuilt += nsText.substring(from: cursor)
        return (rebuilt, vaultedURLs)
    }

    private static func restoreVaultedURLs(in text: String, prefix: String, vaultedURLs: [String]) -> String {
        guard !vaultedURLs.isEmpty else { return text }
        let nsText = text as NSString
        let totalLength = nsText.length
        var result = ""
        result.reserveCapacity(text.count)
        var pos = 0
        while pos < totalLength {
            let found = nsText.range(of: prefix, options: [], range: NSRange(location: pos, length: totalLength - pos))
            if found.location == NSNotFound {
                result += nsText.substring(from: pos)
                break
            }
            result += nsText.substring(with: NSRange(location: pos, length: found.location - pos))
            let numStart = found.location + found.length
            let endFound = nsText.range(
                of: "\u{001F}", options: [], range: NSRange(location: numStart, length: totalLength - numStart))
            if endFound.location != NSNotFound && endFound.location > numStart,
                let idx = Int(nsText.substring(with: NSRange(location: numStart, length: endFound.location - numStart))),
                idx >= 0 && idx < vaultedURLs.count
            {
                result += vaultedURLs[idx]
                pos = endFound.location + endFound.length
            } else {
                result += prefix
                pos = numStart
            }
        }
        return result
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
        let chars = Array(qf)
        var excess = Self.countExcessClosers(chars)
        var end = chars.count
        let precededByQuote = matchStart > 0 && nsText.character(at: matchStart - 1) == 0x27
        while end > 1 && Self.shouldTrimCloser(chars[end - 1], precededByQuote: precededByQuote, excess: &excess) {
            end -= 1
        }
        return (String(chars[..<end]), String(chars[end...]))
    }

    private static func countExcessClosers(_ chars: [Character]) -> [Int] {
        var excess = [0, 0, 0]
        for ch in chars {
            switch ch {
            case "(": excess[0] -= 1
            case ")": excess[0] += 1
            case "[": excess[1] -= 1
            case "]": excess[1] += 1
            case "{": excess[2] -= 1
            case "}": excess[2] += 1
            default: break
            }
        }
        return excess
    }

    private static func shouldTrimCloser(_ ch: Character, precededByQuote: Bool, excess: inout [Int]) -> Bool {
        let slot =
            switch ch {
            case ")": 0
            case "]": 1
            case "}": 2
            default: -1
            }
        if slot >= 0 {
            guard excess[slot] > 0 else { return false }
            excess[slot] -= 1
            return true
        }
        return ch == "." || ch == ";" || ch == "," || (ch == "'" && precededByQuote)
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
            + #"([?#][^\s"<>\r\n]*)?(?=$|[\s"'<>\\{},;()\[\]]|file://|[A-Za-z]:[\\/])"#,
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
            (#"(?:[A-Za-z0-9._+-]|%(?!40))+(?:@|%40)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, "[redacted-email]"),
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

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
            let service = try CoreTelemetryService(
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
            if initialEnabled && service.consent == .off {
                defaults.set(false, forKey: "AUNTelemetryEnabled")
            }
            return service
        } catch {
            if initialEnabled {
                defaults.set(false, forKey: "AUNTelemetryEnabled")
            }
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

    private static let vaultPrefix = "\u{001E}AUNURL"

    /// Scrubs local filesystem paths, relative paths, bare filenames, and `file://` URIs while
    /// preserving valid non-`file` RFC 3986 URLs and stack symbols.
    public static func sanitizeLocalPaths(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let (escaped, hadSentinels) = Self.escapeSentinels(text)
        var (scrubbed, vaultedURLs) = Self.vaultNonFileURLs(in: escaped, prefix: Self.vaultPrefix)
        scrubbed = Self.redactFileURIs(in: scrubbed, vaultPrefix: Self.vaultPrefix)
        for rule in Self.preKeywordPathRules {
            let range = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
            scrubbed = rule.regex.stringByReplacingMatches(in: scrubbed, options: [], range: range, withTemplate: rule.template)
        }
        scrubbed = Self.redactKeywordUnquotedFilenames(in: scrubbed)
        for rule in Self.postKeywordPathRules {
            let range = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
            scrubbed = rule.regex.stringByReplacingMatches(in: scrubbed, options: [], range: range, withTemplate: rule.template)
        }
        scrubbed = Self.restoreVaultedURLs(in: scrubbed, prefix: Self.vaultPrefix, vaultedURLs: vaultedURLs)
        scrubbed = Self.redactEmails(in: scrubbed)
        if let bearerRegex = Self.bearerTokenRegex {
            let range = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
            scrubbed = bearerRegex.stringByReplacingMatches(
                in: scrubbed, options: [], range: range, withTemplate: "Bearer [redacted]"
            )
        }
        return hadSentinels ? Self.unescapeSentinels(scrubbed) : scrubbed
    }

    private static func redactEmails(in text: String) -> String {
        guard text.contains("@") || text.contains("%40") else { return text }
        let nsText = text as NSString
        let len = nsText.length
        var result = ""
        var copied = 0
        var idx = 0
        while idx < len {
            let atLen = Self.emailAtLength(nsText, at: idx, len: len)
            if atLen == 0 {
                idx += 1
                continue
            }
            var localStart = idx
            while localStart > copied && Self.isEmailLocalChar(nsText, at: localStart - 1, len: len) {
                localStart -= 1
            }
            let domEnd = localStart < idx ? Self.findEmailDomainEnd(nsText, domStart: idx + atLen, len: len) : -1
            if domEnd > 0 {
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copied, length: localStart - copied))
                result += "[redacted-email]"
                copied = domEnd
                idx = domEnd
            } else {
                idx += atLen
            }
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func emailAtLength(_ nsText: NSString, at pos: Int, len: Int) -> Int {
        let ch = nsText.character(at: pos)
        if ch == 0x40 { return 1 }  // '@'
        if ch == 0x25 && pos + 2 < len && nsText.character(at: pos + 1) == 0x34 && nsText.character(at: pos + 2) == 0x30 {
            return 3  // "%40"
        }
        return 0
    }

    private static func isEmailLocalChar(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        let ch = nsText.character(at: pos)
        if (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x30 && ch <= 0x39)
            || ch == 0x2E || ch == 0x5F || ch == 0x2B || ch == 0x2D
        {
            return true
        }
        return ch == 0x25 && !(pos + 2 < len && nsText.character(at: pos + 1) == 0x34 && nsText.character(at: pos + 2) == 0x30)
    }

    private static func findEmailDomainEnd(_ nsText: NSString, domStart: Int, len: Int) -> Int {
        var idx = domStart
        var lastDot = -1
        var lettersSinceDot = 0
        var bestEnd = -1
        while idx < len {
            let ch = nsText.character(at: idx)
            if (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) {
                lettersSinceDot = lastDot >= 0 ? lettersSinceDot + 1 : 0
            } else if ch == 0x2E {
                lastDot = idx > domStart ? idx : -1
                lettersSinceDot = 0
            } else if (ch >= 0x30 && ch <= 0x39) || ch == 0x2D {
                lettersSinceDot = -1
            } else {
                break
            }
            idx += 1
            if lastDot > domStart && lettersSinceDot >= 2 && (idx == len || !Self.isASCIIWordChar(nsText.character(at: idx))) {
                bestEnd = idx
            }
        }
        return bestEnd
    }

    private static func isASCIIWordChar(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x30 && ch <= 0x39) || ch == 0x5F
    }

    private static func isASCIIAlphaNum(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x30 && ch <= 0x39)
    }

    private static func redactKeywordUnquotedFilenames(in text: String) -> String {
        guard text.contains("."), let kwRegex = Self.keywordFilenamePrefixRegex else { return text }
        let nsText = text as NSString
        let len = nsText.length
        var result = ""
        var copied = 0
        var segStart = 0
        while segStart < len {
            var segEnd = segStart
            while segEnd < len {
                let ch = nsText.character(at: segEnd)
                if ch == 0x0A || ch == 0x0D || ch == 0x1E || ch == 0x1F { break }
                segEnd += 1
            }
            if let (lastDot, lastExtEnd) = Self.findLastUnquotedFilenameExt(nsText, segStart: segStart, segEnd: segEnd, len: len),
                let kwMatch = kwRegex.firstMatch(
                    in: text, options: [], range: NSRange(location: segStart, length: lastDot - segStart)
                )
            {
                let kwEnd = kwMatch.range.location + kwMatch.range.length
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copied, length: kwEnd - copied))
                result += "[redacted-path]"
                copied = lastExtEnd
            }
            segStart = segEnd + 1
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func findLastUnquotedFilenameExt(
        _ nsText: NSString, segStart: Int, segEnd: Int, len: Int
    ) -> (Int, Int)? {
        var dot = segEnd - 1
        while dot >= segStart {
            if nsText.character(at: dot) == 0x2E {
                let extStart = dot + 1
                var extEnd = extStart
                while extEnd < segEnd && extEnd - extStart < 17 && Self.isASCIIAlphaNum(nsText.character(at: extEnd)) {
                    extEnd += 1
                }
                let extLen = extEnd - extStart
                let validBounds =
                    extLen >= 1 && extLen <= 16
                    && (extEnd == len
                        || (!Self.isASCIIWordChar(nsText.character(at: extEnd)) && nsText.character(at: extEnd) != 0x28))
                if validBounds && !Self.isSourceLineReference(nsText, extStart: extStart, extEnd: extEnd, len: len) {
                    return (dot, extEnd)
                }
            }
            dot -= 1
        }
        return nil
    }

    private static func isSourceLineReference(_ nsText: NSString, extStart: Int, extEnd: Int, len: Int) -> Bool {
        guard extEnd + 1 < len && nsText.character(at: extEnd) == 0x3A else { return false }
        let digit = nsText.character(at: extEnd + 1)
        guard digit >= 0x30 && digit <= 0x39 else { return false }
        let ext = nsText.substring(with: NSRange(location: extStart, length: extEnd - extStart)).lowercased()
        return Self.sourceLineExtSet.contains(ext)
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

    private static let sourceLineExtSet: Set<String> = [
        "kt", "java", "swift", "cs", "cpp", "cc", "c", "h", "hpp", "rs", "py", "js", "ts", "go", "rb", "m", "mm",
    ]

    private static let keywordFilenamePrefixRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(?:"# + ioKeywordVerbs + #")\b(?:[^\S\r\n]*[:=][^\S\r\n]*|[^\S\r\n]+)"#,
        options: [.caseInsensitive]
    )

    private static let preKeywordPathRules: [(regex: NSRegularExpression, template: String)] = {
        let specs: [(String, String)] = [
            (#"(\()(?:/|~/|[A-Za-z]:[\\/]|\\\\)[^()\r\n\u001E]+(\))"#, "$1[redacted-path]$2"),
            (
                #"(\()(?!(?:HTTP|TLS|SSL)/\d)(?!\d+/\d+[.,;:!?]?\))[^\s/\\"'<>()\[\]{}:,;\u001E\u001F]+/[^()\r\n\u001E]+(\))"#,
                "$1[redacted-path]$2"
            ),
            (#"(?:[A-Za-z]:[\\/]|\\\\)[^\S\r\n]*[^\r\n\u001E\s]+(?:[^\S\r\n]+[^\r\n\u001E\s]+)*"#, "[redacted-path]"),
            (
                #"(^|[\s(\[{"'=,:;\u001F])[^\s\\/"'<>(),;\u001E\u001F]+\\[^\r\n\u001E\u001F\s]+(?:[^\S\r\n]+[^\r\n\u001E\u001F\s]+)*"#,
                "$1[redacted-path]"
            ),
            (#"["']/[ \t]+[^\r\n\u001E]+"#, "[redacted-path]"),
            (
                #"(?<![\p{L}\p{M}\p{N}._/-])(?:~/|//+(?=[ \t]*[^\s/])|/(?=[ \t]*[^\s/]))[^\S\r\n]*[^\r\n\u001E\s]+(?:[^\S\r\n]+[^\r\n\u001E\s]+)*"#,
                "[redacted-path]"
            ),
            (
                #"(^|[\s(\[{"'=,:;\u001F])(?!(?<!['"])(?:HTTP|TLS|SSL)/\d)"#
                    + #"(?!(?<!['"])\d+/\d+(?:$|[\s)\]},;:!?]|\.(?![A-Za-z0-9])))"#
                    + #"[^\s/\\"'<>()\[\]{}:,;\u001E\u001F]+/[^\r\n\u001E\u001F\s]+(?:[^\S\r\n]+[^\r\n\u001E\u001F\s]+)*"#,
                "$1[redacted-path]"
            ),
            (#""[^"\r\n/\\]*\.[A-Za-z0-9]{1,16}""#, "[redacted-path]"),
            (#"(?<!\p{L})'(?:[^'\r\n/\\]|(?<=\p{L})'(?=\p{L}))*\.[A-Za-z0-9]{1,16}'"#, "[redacted-path]"),
            (#"(\b(?:file|path|directory|folder|document)\s+)(['"])(?!\u001E)[^'"\r\n]+\2"#, "$1[redacted-path]"),
        ]
        return specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, template)
        }
    }()

    private static let postKeywordPathRules: [(regex: NSRegularExpression, template: String)] = {
        let specs: [(String, String)] = [
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

    private static let bearerTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\bBearer\s+\S+"#, options: [.caseInsensitive]
    )

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

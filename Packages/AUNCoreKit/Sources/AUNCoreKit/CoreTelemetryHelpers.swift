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
        let preAuth = CoreTelemetryAuthScanner.redactAuthCredentials(in: VaultLineTracker.redactQuotedEmails(in: escaped))
        var (scrubbed, vaultedURLs) = Self.vaultNonFileURLs(in: preAuth, prefix: Self.vaultPrefix)
        scrubbed = Self.redactFileURIs(in: scrubbed, vaultPrefix: Self.vaultPrefix)
        scrubbed = Self.redactDoubleQuotedLocalPaths(in: scrubbed)
        for regex in Self.parenPathRegexes {
            scrubbed = Self.replaceUnquotedParenPaths(in: scrubbed, using: regex)
        }
        scrubbed = Self.replacePreKeywordPathRules(in: scrubbed, rules: Self.preKeywordPathRules)
        scrubbed = Self.redactQuotedFilenames(in: scrubbed)
        if let kwQuote = Self.keywordQuotedPathRegex {
            let range = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
            scrubbed = kwQuote.stringByReplacingMatches(
                in: scrubbed, options: [], range: range, withTemplate: "$1[redacted-path]")
        }
        scrubbed = Self.redactKeywordUnquotedFilenames(in: scrubbed)
        if let kwAssign = Self.keywordAssignedPathRegex {
            scrubbed = Self.replaceKeywordAssignedPaths(in: scrubbed, regex: kwAssign)
        }
        scrubbed = Self.redactEmails(in: scrubbed)
        if scrubbed.contains("."), let bareRegex = Self.bareFilenameRegex {
            let range = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
            scrubbed = bareRegex.stringByReplacingMatches(
                in: scrubbed, options: [], range: range, withTemplate: "$1$2[redacted-path]")
        }
        scrubbed = Self.restoreVaultedURLs(in: scrubbed, prefix: Self.vaultPrefix, vaultedURLs: vaultedURLs)
        if !vaultedURLs.isEmpty {
            scrubbed = Self.redactEmails(in: scrubbed)
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
        var quoteCacheUntil = -1
        var cachedNextQuote = -1
        while idx < len {
            if nsText.character(at: idx) == 0x22
                && !VaultLineTracker.isPrecededByOddBackslashes(nsText, at: idx, minPos: copied)
            {
                if let qEnd = VaultLineTracker.matchQuotedEmailEnd(
                    nsText, at: idx, cacheUntil: &quoteCacheUntil, cachedClose: &cachedNextQuote
                ) {
                    if result.isEmpty { result.reserveCapacity(text.count) }
                    result += nsText.substring(with: NSRange(location: copied, length: idx - copied))
                    result += "[redacted-email]"
                    copied = qEnd
                    idx = qEnd
                    quoteCacheUntil = -1
                    continue
                }
                idx += 1
                continue
            }
            let atLen = VaultLineTracker.emailAtLength(nsText, at: idx, len: len)
            if atLen == 0 {
                idx += 1
                continue
            }
            let domEnd = VaultLineTracker.findEmailDomainEnd(nsText, domStart: idx + atLen, len: len)
            let localStart = domEnd > 0 ? VaultLineTracker.findEmailLocalStart(nsText, at: idx, minPos: copied, len: len) : idx
            if domEnd > 0 && localStart < idx {
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copied, length: localStart - copied))
                result += "[redacted-email]"
                copied = domEnd
                idx = domEnd
                quoteCacheUntil = -1
            } else {
                idx += atLen
            }
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func isASCIIWordChar(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x30 && ch <= 0x39) || ch == 0x5F
    }

    static func isASCIIAlphaNum(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x30 && ch <= 0x39)
    }

    private static func redactKeywordUnquotedFilenames(in text: String) -> String {
        guard text.contains("."), let kwRegex = Self.keywordFilenamePrefixRegex else { return text }
        let hasAt = VaultLineTracker.hasEmailAt(text)
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
                let emailEnd = hasAt ? VaultLineTracker.findEmailTailEnd(nsText, from: lastExtEnd, len: len) : -1
                if emailEnd > 0 && !VaultLineTracker.containsWhitespace(nsText, from: kwEnd, to: lastDot) {
                    segStart = segEnd + 1
                    continue
                }
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copied, length: kwEnd - copied))
                result += "[redacted-path]"
                copied = max(lastExtEnd, emailEnd)
            }
            segStart = max(segEnd + 1, copied)
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

    static func vaultNonFileURLs(in text: String, prefix: String) -> (String, [String]) {
        var vaultedURLs: [String] = []
        let scrubbed = Self.vaultNonFileURLsInto(text, prefix: prefix, vaultedURLs: &vaultedURLs)
        return (scrubbed, vaultedURLs)
    }

    static func vaultNonFileURLsInto(_ text: String, prefix: String, vaultedURLs: inout [String]) -> String {
        guard text.contains("://") else { return text }
        let nsText = text as NSString
        let totalLen = nsText.length
        let startCount = vaultedURLs.count
        var tracker = VaultLineTracker()
        var rebuilt = ""
        var copied = 0
        var searchFrom = 0
        var quoteCursor = 0
        var quoteState = 0
        var contLimits = ContinuationLimits()
        while searchFrom < totalLen {
            let found = nsText.range(
                of: "://", options: [], range: NSRange(location: searchFrom, length: totalLen - searchFrom)
            )
            if found.location == NSNotFound { break }
            let sep = found.location
            guard let start = Self.findNonFileSchemeStart(nsText, sep: sep, minStart: copied) else {
                searchFrom = sep + 3
                continue
            }
            if tracker.isEmbeddedInPath(nsText, matchStart: start) {
                searchFrom = sep + 3
                continue
            }
            if start > quoteCursor {
                quoteState = Self.advanceQuoteState(nsText, from: quoteCursor, to: start, quoteState: quoteState)
                quoteCursor = start
            }
            let angleMask = Self.computeQueryAngleStopMask(nsText, urlStart: start, inDoubleQuote: (quoteState & 2) != 0)
            guard let span = Self.scanURLAfterScheme(nsText, start: start, sep: sep, angleStopMask: angleMask)
            else {
                searchFrom = sep + 3
                continue
            }
            let inSingleQuote = (quoteState & 1) != 0
            let baseURL = nsText.substring(with: NSRange(location: span.start, length: span.baseEnd - span.start))
            let (url, tail): (String, String)
            if span.hasQueryOrFragment {
                let qf = nsText.substring(with: NSRange(location: span.baseEnd, length: span.totalEnd - span.baseEnd))
                let (cleanQF, trimmedTail) = Self.trimQueryOrFragmentDelimiters(
                    qf, nsText: nsText, matchStart: span.start, inSingleQuote: inSingleQuote
                )
                let marker = cleanQF.first.map(String.init) ?? "?"
                url = "\(baseURL)\(marker)[redacted]"
                tail = trimmedTail
            } else {
                (url, tail) = Self.trimTrailingURLDelimiters(
                    baseURL, nsText: nsText, matchStart: span.start, inSingleQuote: inSingleQuote
                )
            }
            let redactedURL = Self.redactURLPathSecrets(url)
            var endPos = span.totalEnd
            var finalTail = tail
            rebuilt += nsText.substring(with: NSRange(location: copied, length: span.start - copied))
            let contInput = URLContinuationInput(
                span: span, rawURL: baseURL, baseTail: tail, quoteState: quoteState
            )
            if let ext = Self.extendURLContinuation(nsText, input: contInput, limits: &contLimits) {
                endPos = ext.endPos
                finalTail = ext.tail
                rebuilt += Self.formatURLContinuation(
                    ext, prefix: prefix, baseRedacted: redactedURL, baseTail: tail, vaultedURLs: &vaultedURLs
                )
            } else {
                let idx = vaultedURLs.count
                vaultedURLs.append(redactedURL)
                rebuilt += "\(prefix)\(idx)\u{001F}\(tail)"
            }
            let nsTail = finalTail as NSString
            quoteState = Self.advanceQuoteState(nsTail, from: 0, to: nsTail.length, quoteState: quoteState)
            tracker.onVaultedURL(matchEnd: endPos)
            copied = endPos
            quoteCursor = endPos
            searchFrom = endPos
        }
        guard vaultedURLs.count > startCount else { return text }
        rebuilt += nsText.substring(from: copied)
        return rebuilt
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

    private static let keywordQuotedPathRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(\b(?:file|path|directory|folder|document)[^\S\r\n]+)([""'])(?!\u001E)[^'""\r\n]+\2"#,
        options: [.caseInsensitive]
    )

    private static let keywordFilenamePrefixRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(?:"# + ioKeywordVerbs + #")\b(?:[^\S\r\n]*[:=][^\S\r\n]*|[^\S\r\n]+)"#,
        options: [.caseInsensitive]
    )

    private static let parenPathRegexes: [NSRegularExpression] = [
        #"(\()(?:/|~/|[A-Za-z]:[\\/]|\\\\)[^()\r\n\u001E]+(\))"#,
        #"(\()(?![ \t]*(?:HTTP|TLS|SSL)/\d)(?![ \t]*\d+/\d+[.,;:!?\s]*\))"#
            + #"[^\s/\\"'<>()\[\]{}:,;=\u001E\u001F]+/[^()\r\n\u001E]+(\))"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let preKeywordPathRules: [(regex: NSRegularExpression, template: String)] = {
        let absTail = #"[^\r\n\u001E\s](?:[^\r\n\u001E]*[^\r\n\u001E\s])?"#
        let absNonQuoteTail = #"[^\r\n\u001E\s"](?:[^\r\n\u001E]*[^\r\n\u001E\s])?"#
        let relNonQuoteTail = #"[^\r\n\u001E\u001F\s"](?:[^\r\n\u001E\u001F]*[^\r\n\u001E\u001F\s])?"#
        let specs: [(String, String)] = [
            (#"(?:[A-Za-z]:[\\/]|\\\\)[^\S\r\n]*"# + absNonQuoteTail, "[redacted-path]"),
            (#"(^|[\s(\[{"'=,:;<>)\u001F])[^\s\\/"'<>()\[{:,;=\u001E\u001F]+\\"# + relNonQuoteTail, "$1[redacted-path]"),
            (#"["']/[ \t]+[^\r\n\u001E\s"][^\r\n\u001E]*"#, "[redacted-path]"),
            (
                #"(?<![\p{L}\p{M}\p{N}._/-])(?:~/(?=[^\S\r\n]*[^\s"])|//+(?=[^\S\r\n]*[^\s/"])|/(?=[^\S\r\n]*[^\s/"]))[^\S\r\n]*"#
                    + absTail,
                "[redacted-path]"
            ),
            (
                #"(^|[\s(\[{)\]}<>"'=,:;\u001F])(?!(?<!['"])(?:HTTP|TLS|SSL)/\d)"#
                    + #"(?!(?<!['"])\d+/\d+(?:$|[\s)\]},;:!?]|\.(?![A-Za-z0-9])))"#
                    + #"[^\s/\\"'<>()\[\]{}:,;=\u001E\u001F]+/"# + relNonQuoteTail,
                "$1[redacted-path]"
            ),
        ]
        return specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, template)
        }
    }()

    private static let keywordAssignedPathRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(\b(?:file|path|filename|filepath)\s*[:=]\s*)(?!\u001E)[^\r\n\u001E\u001F]+"#,
        options: [.caseInsensitive]
    )

    private static let bareFilenameRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(^|[\r\n:=;\u001F"])([ \t]*)(?=[^\r\n:=;\u001E\u001F" \t])[^\r\n:=;\u001E\u001F"]*\."#
            + #"(?!ts:\d+)(?:"# + bareFilenameExtensions + #")\b(?!\()"#,
        options: [.caseInsensitive]
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

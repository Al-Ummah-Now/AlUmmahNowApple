import Foundation

extension CoreTelemetryService {
    static let bareFilenameExtensions =
        "mov|mp4|m4v|mkv|webm|avi|flv|wmv|ogv|3gp|ts|m3u8|mpd|mp3|m4a|wav|aac|flac|ogg|opus|wma|aiff|alac|mid|midi|"
        + "jpg|jpeg|png|gif|webp|heic|svg|tif|tiff|bmp|ico|avif|jxl|raw|cr2|cr3|nef|arw|dng|"
        + "blend|psd|psb|ai|eps|indd|aep|prproj|drp|fcpx|fcpxml|kdenlive|mlt|veg|xcf|kra|fig|sketch|afdesign|afphoto|"
        + "fbx|obj|gltf|glb|stl|usd|usdz|"
        + "pdf|txt|md|rtf|doc|docx|xls|xlsx|ppt|pptx|odt|ods|odp|pages|numbers|keynote|epub|mobi|"
        + "csv|json|xml|yaml|yml|toml|ini|cfg|conf|log|srt|vtt|ass|ssa|parquet|avro|orc|feather|hdf5|h5|"
        + "zip|tar|gz|tgz|bz2|xz|7z|rar|dmg|pkg|msi|exe|apk|aab|ipa|iso|img|vhd|vhdx|vmdk|ova|ovf|"
        + "deb|rpm|appimage|snap|flatpak|cab|jar|war|ear|whl|egg|nupkg|vsix|crx|xpi|"
        + "pem|key|crt|cer|cert|der|p12|pfx|jks|jceks|keystore|kdbx|ovpn|ppk|pub|asc|gpg|pgp|sig|"
        + "db|sqlite|sqlite3|sql|dump|pkl|pickle|joblib|pt|pth|onnx|safetensors|gguf|"
        + "bin|dat|tmp|bak|old|orig|swp|swo|proj|aun|env|har|pcap|pcapng|dmp|hdmp|mdmp|heapsnapshot"

    private static let webhookPathTokenRegex = try? NSRegularExpression(
        pattern: #"((?:^|/|%2[fF])(?:webhooks?|reset|reset-password|password-reset|forgot-password|"#
            + #"verify|verify-email|confirm|confirm-email|activate|magic|magic-link|"#
            + #"invite|invitations?|tokens?|auth|oauth2?|callback|sessions?|unsubscribe|"#
            + #"secrets?|keys?|api-?keys?|credentials?|sign-?in|login|sso|redeem|claim|recovery?|passwords?|"#
            + #"share|shared|sh|s|scl|dl|link|private|join|otp|passkey|code|folders|"#
            + #"(?:file|document|spreadsheets|presentation)/(?:u/\d+/)?d)"#
            + #"(?:/|%2[fF]))[^\s?#]+"#,
        options: [.caseInsensitive]
    )
    private static let slackWebhookHostRegex = try? NSRegularExpression(
        pattern: #"https?://hooks\.slack(?:-gov)?\.com\.?(?::\d*)?(?=(?:/|%2[fF]))"#, options: [.caseInsensitive]
    )
    private static let slackWebhookRouteRegex = try? NSRegularExpression(
        pattern: #"((?:/|%2[fF])(?:services|workflows|triggers)(?:/|%2[fF]))[^\s?#]+"#, options: [.caseInsensitive]
    )
    private static let telegramBotTokenURLRegex = try? NSRegularExpression(
        pattern: #"((?:/|%2[fF])bot\d+:)[^/\s?#]+"#, options: [.caseInsensitive]
    )
    private static let urlMatrixParamRegex = try? NSRegularExpression(
        pattern:
            #"(;[a-z0-9_-]*(?:session|jsessionid|phpsessid|sid|token|secret|auth|key|pass|pwd|cred|jwt|sig|code|otp|ticket|cookie)[a-z0-9_-]*=)[^/?#;\s]+"#,
        options: [.caseInsensitive]
    )

    static func redactURLPathSecrets(_ url: String) -> String {
        var result = url
        if let regex = webhookPathTokenRegex {
            result = replaceURLPathSecret(result, regex: regex)
        }
        result = redactSlackWebhookURL(result)
        if let regex = telegramBotTokenURLRegex {
            result = replaceURLPathSecret(result, regex: regex)
        }
        if let regex = urlMatrixParamRegex {
            result = replaceURLPathSecret(result, regex: regex)
        }
        return result
    }

    private static func redactSlackWebhookURL(_ url: String) -> String {
        guard let hostRegex = slackWebhookHostRegex, let routeRegex = slackWebhookRouteRegex else { return url }
        let decoded: String
        let origOffsets: [Int]?
        if url.contains("%") {
            let pair = decodeURLForPathSecretMatch(url)
            decoded = pair.0
            origOffsets = pair.1
        } else {
            decoded = url
            origOffsets = nil
        }
        let nsDecoded = decoded as NSString
        guard
            let hostMatch = hostRegex.firstMatch(
                in: decoded, options: [], range: NSRange(location: 0, length: nsDecoded.length)
            )
        else { return url }
        let hostEnd = hostMatch.range.location + hostMatch.range.length
        var pathEnd = hostEnd
        while pathEnd < nsDecoded.length {
            let ch = nsDecoded.character(at: pathEnd)
            if VaultLineTracker.isWhitespace(ch) || ch == 0x3F || ch == 0x23 { break }
            pathEnd += 1
        }
        guard
            let routeMatch = routeRegex.firstMatch(
                in: decoded, options: [], range: NSRange(location: hostEnd, length: pathEnd - hostEnd)
            )
        else { return url }
        let g1 = routeMatch.range(at: 1)
        let rawStart = g1.location + g1.length
        let rawEnd = routeMatch.range.location + routeMatch.range.length
        let secretStart = origOffsets?[rawStart] ?? rawStart
        let secretEnd = origOffsets?[rawEnd] ?? rawEnd
        let nsURL = url as NSString
        return nsURL.substring(with: NSRange(location: 0, length: secretStart)) + "[redacted]"
            + nsURL.substring(from: secretEnd)
    }

    private static func replaceURLPathSecret(_ url: String, regex: NSRegularExpression) -> String {
        if !url.contains("%") {
            let range = NSRange(url.startIndex..<url.endIndex, in: url)
            return regex.stringByReplacingMatches(in: url, options: [], range: range, withTemplate: "$1[redacted]")
        }
        let (decoded, origOffsets) = decodeURLForPathSecretMatch(url)
        let nsDecoded = decoded as NSString
        let matches = regex.matches(in: decoded, options: [], range: NSRange(location: 0, length: nsDecoded.length))
        guard !matches.isEmpty else { return url }
        let nsURL = url as NSString
        var rebuilt = ""
        var copied = 0
        for match in matches {
            let g1 = match.range(at: 1)
            let secretStart = origOffsets[g1.location + g1.length]
            if secretStart < copied { continue }
            let secretEnd = origOffsets[match.range.location + match.range.length]
            rebuilt += nsURL.substring(with: NSRange(location: copied, length: secretStart - copied))
            rebuilt += "[redacted]"
            copied = secretEnd
        }
        guard copied > 0 else { return url }
        rebuilt += nsURL.substring(from: copied)
        return rebuilt
    }

    private static func decodeURLForPathSecretMatch(_ url: String) -> (String, [Int]) {
        let nsURL = url as NSString
        let len = nsURL.length
        var decodedUnits: [unichar] = []
        decodedUnits.reserveCapacity(len)
        var offsets: [Int] = []
        offsets.reserveCapacity(len + 1)
        var idx = 0
        while idx < len {
            offsets.append(idx)
            let ch = nsURL.character(at: idx)
            if ch == 0x25, idx + 2 < len,
                let byteVal = parseHexByte(nsURL.character(at: idx + 1), nsURL.character(at: idx + 2)),
                isDecodablePathSecretByte(byteVal)
            {
                decodedUnits.append(unichar(byteVal))
                idx += 3
            } else {
                decodedUnits.append(ch)
                idx += 1
            }
        }
        offsets.append(len)
        return (String(utf16CodeUnits: decodedUnits, count: decodedUnits.count), offsets)
    }

    private static func isDecodablePathSecretByte(_ byteVal: UInt8) -> Bool {
        byteVal >= 0x21 && byteVal <= 0x7E && byteVal != 0x2F && byteVal != 0x3F && byteVal != 0x23
    }

    private static func parseHexByte(_ hi: unichar, _ lo: unichar) -> UInt8? {
        guard let h = hexNibble(hi), let l = hexNibble(lo) else { return nil }
        return (h << 4) | l
    }

    private static func hexNibble(_ ch: unichar) -> UInt8? {
        if ch >= 0x30 && ch <= 0x39 { return UInt8(ch - 0x30) }
        if ch >= 0x61 && ch <= 0x66 { return UInt8(ch - 0x61 + 10) }
        if ch >= 0x41 && ch <= 0x46 { return UInt8(ch - 0x41 + 10) }
        return nil
    }

    private static let sensitiveCustomHeaderSegments: Set<String> = [
        "token", "secret", "key", "auth", "authorization",
        "password", "passwd", "credential", "credentials", "signature", "session", "cookie",
    ]

    static func isSensitiveCustomHeader(_ lower: String) -> Bool {
        let count = lower.utf8.count
        guard count >= 4 && count <= 48 && (lower.hasPrefix("x-") || lower.hasPrefix("x_")) else { return false }
        for b in lower.utf8 {
            let ok = (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x5F
            if !ok { return false }
        }
        return lower.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .contains { sensitiveCustomHeaderSegments.contains(String($0)) }
    }

    private static let jwtInKeyRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+){1,3}(?![A-Za-z0-9_-])"#
    )
    private static let ipv4InKeyRegex = try? NSRegularExpression(
        pattern:
            #"(?<![A-Za-z0-9_.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![A-Za-z0-9_]|\.\d)"#
    )
    private static let ipv6InKeyRegex = try? NSRegularExpression(
        pattern:
            #"(?<![0-9a-fA-F]:)(?<![A-Za-z0-9_])(?:(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|"#
            + #"(?:[0-9a-fA-F]{1,4}:){1,7}:(?:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){0,5})?|"#
            + #"::(?:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){0,6}))(?:%[A-Za-z0-9_.-]+)?(?![A-Za-z0-9_]|:[0-9a-fA-F])"#
    )
    private static let phoneInKeyRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])\+?\p{Nd}[\p{Nd}\s().\p{Pd}]{7,}\p{Nd}(?![A-Za-z0-9_])"#
    )
    private static let opaqueSecretInKeyRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])[A-Za-z0-9+/=_-]{32,}(?![A-Za-z0-9_])"#
    )
    private static let uuidExactRegex = try? NSRegularExpression(
        pattern: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
    )

    static func observeDefaultsOptOut(
        _ defaults: UserDefaults?, key: String?, onOptOut: @escaping @Sendable () -> Void
    ) -> NSObjectProtocol? {
        guard let defaults, let key else { return nil }
        nonisolated(unsafe) let defaultsRef = defaults
        return NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { _ in
            if !defaultsRef.bool(forKey: key) { onOptOut() }
        }
    }

    private static let keyValueCredentialRegex = try? NSRegularExpression(
        pattern:
            #"(?<![A-Za-z0-9_])(token|secret|jwt|passphrase|credential|credentials|"#
            + #"verification[_-]?code|auth[_-]?code|recovery[_-]?code|passcode|otp|pin|"#
            + #"client[_-]?secret|access[_-]?token|refresh[_-]?token|id[_-]?token|"#
            + #"api[_-]?key|api[_-]?token|auth[_-]?token|session[_-]?token|security[_-]?token|"#
            + #"private[_-]?key|secret[_-]?key|access[_-]?key|code[_-]?verifier|"#
            + #"session[_-]?id|session[_-]?key|password|passwd)(\s*[=:]\s*)"#
            + #"(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s,;}\]]+)"#,
        options: [.caseInsensitive]
    )

    static func sanitizeDiagnosticText(_ text: String) -> String {
        var safe = sanitizeLocalPaths(text)
        if let regex = keyValueCredentialRegex {
            let range = NSRange(location: 0, length: (safe as NSString).length)
            safe = regex.stringByReplacingMatches(in: safe, options: [], range: range, withTemplate: "$1$2[redacted]")
        }
        if let regex = ipv4InKeyRegex {
            safe = replaceMatches(in: safe, regex: regex) { _ in "[redacted-ip]" }
        }
        if let regex = ipv6InKeyRegex {
            safe = replaceMatches(in: safe, regex: regex) { _ in "[redacted-ip]" }
        }
        if let regex = phoneInKeyRegex {
            safe = replaceMatches(in: safe, regex: regex) { match in
                match.unicodeScalars.filter { $0.properties.generalCategory == .decimalNumber }.count >= 9
                    ? "[redacted-phone]" : nil
            }
        }
        return safe
    }

    static func sanitizePropertyKey(_ key: String) -> String {
        var safe = sanitizeDiagnosticText(key)
        if let regex = jwtInKeyRegex {
            safe = replaceMatches(in: safe, regex: regex) { _ in "[redacted-token]" }
        }
        if let regex = opaqueSecretInKeyRegex {
            safe = replaceMatches(in: safe, regex: regex) { match in
                let hasLetter = match.utf8.contains { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }
                let hasDigit = match.utf8.contains { $0 >= 0x30 && $0 <= 0x39 }
                let isUUID =
                    uuidExactRegex?.firstMatch(
                        in: match, options: [], range: NSRange(location: 0, length: (match as NSString).length)
                    ) != nil
                return hasLetter && hasDigit && !isUUID ? "[redacted]" : nil
            }
        }
        return safe
    }

    private static func replaceMatches(
        in text: String, regex: NSRegularExpression, transform: (String) -> String?
    ) -> String {
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var copied = 0
        for m in matches {
            let sub = nsText.substring(with: m.range)
            guard let repl = transform(sub) else { continue }
            out += nsText.substring(with: NSRange(location: copied, length: m.range.location - copied))
            out += repl
            copied = m.range.location + m.range.length
        }
        guard copied > 0 else { return text }
        out += nsText.substring(from: copied)
        return out
    }

    static func isKnownAuthHeaderPropertyKey(_ trimmedKey: String) -> Bool {
        let lower = trimmedKey.lowercased()
        switch lower {
        case "authorization", "proxy-authorization", "cookie", "set-cookie",
            "x-amz-security-token", "x-amz-credential", "x-amz-signature", "x-goog-api-key",
            "x-csrf-token", "x-xsrf-token", "x-session-token", "x-session-id",
            "x-secret-key", "x-client-secret", "x-token",
            "x-api-key", "api-key", "api_key", "x-auth-token", "x-access-token", "x-api-token",
            "auth_token", "api_token", "access_token", "access-token",
            "refresh_token", "refresh-token", "id_token", "id-token",
            "session_token", "session-token", "security_token", "security-token",
            "session_key", "session-key", "session_id", "session-id",
            "private_key", "private-key", "privatekey", "secret_key", "secret-key", "secretkey",
            "access_key", "access-key", "accesskey",
            "code_verifier", "code-verifier", "codeverifier",
            "client_secret", "client-secret", "clientsecret",
            "accesstoken", "refreshtoken", "idtoken", "apikey", "apitoken", "authtoken",
            "sessiontoken", "securitytoken", "sessionid", "sessionkey",
            "verification_code", "verification-code", "verificationcode",
            "auth_code", "auth-code", "authcode", "recovery_code", "recovery-code", "recoverycode",
            "passcode", "otp", "pin", "passphrase", "credential", "credentials",
            "authorizationsignature", "authorization-signature", "password", "passwd", "token", "secret", "jwt":
            return true
        default:
            return isSensitiveCustomHeader(lower)
        }
    }

    static func decodeDomainScalar(_ nsText: NSString, at pos: Int, len: Int) -> (UnicodeScalar, Int)? {
        let ch = nsText.character(at: pos)
        if ch >= 0xD800 && ch <= 0xDBFF {
            guard pos + 1 < len else { return nil }
            let low = nsText.character(at: pos + 1)
            guard low >= 0xDC00 && low <= 0xDFFF else { return nil }
            let codePoint = 0x10000 + ((Int(ch) - 0xD800) << 10) + (Int(low) - 0xDC00)
            return UnicodeScalar(codePoint).map { ($0, 2) }
        }
        guard ch < 0xDC00 || ch > 0xDFFF else { return nil }
        return UnicodeScalar(ch).map { ($0, 1) }
    }

    static func tryScanEmbeddedQueryQuote(
        _ nsText: NSString, start: Int, pos: Int, len: Int, angleStopMask: Int
    ) -> Int? {
        guard (angleStopMask & 4) == 0 && pos > start else { return nil }
        let prev = nsText.character(at: pos - 1)
        guard prev == 0x3D || prev == 0x3F || prev == 0x26 || prev == 0x23 else { return nil }
        let ch = nsText.character(at: pos)
        if ch == 0x22 {
            var bs = 0
            while pos - 1 - bs > start && nsText.character(at: pos - 1 - bs) == 0x5C { bs += 1 }
            guard (bs & 1) == 0 else { return nil }
            return scanEmbeddedQueryQuoteEnd(nsText, openPos: pos, len: len, quote: 0x22, requireClose: false)
        }
        if ch == 0x27 {
            let after = scanEmbeddedQueryQuoteEnd(nsText, openPos: pos, len: len, quote: 0x27, requireClose: true)
            return after > pos ? after : nil
        }
        return nil
    }

    private static func scanEmbeddedQueryQuoteEnd(
        _ nsText: NSString, openPos: Int, len: Int, quote: unichar, requireClose: Bool
    ) -> Int {
        var idx = openPos + 1
        var escaped = false
        while idx < len {
            let c = nsText.character(at: idx)
            if c == 0x0A || c == 0x0D { return requireClose ? openPos : idx }
            if c == quote && !escaped { return idx + 1 }
            escaped = c == 0x5C && !escaped
            idx += 1
        }
        return requireClose ? openPos : idx
    }

    static func classifyPercentDomainChar(
        _ nsText: NSString, at pos: Int, len: Int
    ) -> (VaultLineTracker.DomainCharKind, Int)? {
        guard pos + 2 < len && nsText.character(at: pos) == 0x25,
            let b0 = parseHexByte(nsText.character(at: pos + 1), nsText.character(at: pos + 2))
        else { return nil }
        if b0 < 0x80 {
            let ch = unichar(b0)
            if isASCIILetter(ch) { return (.letter, 3) }
            if isASCIIDigit(ch) { return (.digit, 3) }
            if ch == 0x2E { return (.dot, 3) }
            return (ch == 0x2D ? .hyphen : .other, 3)
        }
        return classifyPercentUTF8DomainChar(nsText, at: pos, len: len, firstByte: b0)
    }

    private static func classifyPercentUTF8DomainChar(
        _ nsText: NSString, at pos: Int, len: Int, firstByte b0: UInt8
    ) -> (VaultLineTracker.DomainCharKind, Int)? {
        let count: Int =
            switch b0 {
            case 0xC2...0xDF: 2
            case 0xE0...0xEF: 3
            case 0xF0...0xF4: 4
            default: 0
            }
        guard count > 0 && pos + count * 3 <= len else { return nil }
        var bytes: [UInt8] = [b0]
        for idx in 1..<count {
            let off = pos + idx * 3
            guard nsText.character(at: off) == 0x25,
                let next = parseHexByte(nsText.character(at: off + 1), nsText.character(at: off + 2)),
                next >= 0x80 && next <= 0xBF
            else { return nil }
            bytes.append(next)
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8),
            decoded.unicodeScalars.count == 1,
            let scalar = decoded.unicodeScalars.first
        else { return nil }
        if scalar.value <= 0xFFFF && VaultLineTracker.isEmailDomainDot(unichar(scalar.value)) {
            return (.dot, count * 3)
        }
        if CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
            return (.letter, count * 3)
        }
        return (CharacterSet.decimalDigits.contains(scalar) ? .digit : .other, count * 3)
    }
}

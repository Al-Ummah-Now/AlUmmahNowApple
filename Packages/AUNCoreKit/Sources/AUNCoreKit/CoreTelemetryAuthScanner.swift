import Foundation

/// Linear O(n) auth-header scanner (plain text, JSON escaped keys, arrays) and RFC 7617 Basic / Bearer redactor.
enum CoreTelemetryAuthScanner {
    private static let knownAuthSchemes = [
        "Bearer", "Basic", "Digest", "Token", "Api-Key", "ApiKey",
        "OAuth", "Negotiate", "Mutual", "HOBA", "Vapid", "SCRAM-SHA-256", "AWS4-HMAC-SHA256",
    ]

    private static let bearerTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(Bearer)\s+(?!\[redacted\](?=$|[\s"',;)\]}]))[^\s"',;)\]}]+"#,
        options: [.caseInsensitive]
    )

    private static let basicTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(Basic)\s+([A-Za-z0-9+/_-]{2,}={0,2})(?![A-Za-z0-9+/_=-])"#,
        options: [.caseInsensitive]
    )

    static func redactAuthCredentials(in text: String) -> String {
        var result = redactAuthHeaders(in: text)
        if let bearerRegex = bearerTokenRegex {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = bearerRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1 [redacted]")
        }
        return redactBasicTokens(in: result)
    }

    private struct AuthKeyMatch {
        let keyStart: Int
        let keyEnd: Int
        let allowNewlines: Bool
        let normalizedKey: String?
    }

    private static func redactAuthHeaders(in text: String) -> String {
        guard text.contains(":") || text.contains("=") else { return text }
        let nsText = text as NSString
        let len = nsText.length
        var result = ""
        var copied = 0
        var idx = 0
        while idx < len {
            guard let keyMatch = matchAuthHeaderKey(nsText, at: idx, len: len) else {
                idx += 1
                continue
            }
            let sep = skipAuthWhitespace(nsText, from: keyMatch.keyEnd, len: len, allowNewlines: keyMatch.allowNewlines)
            guard sep < len && (nsText.character(at: sep) == 0x3A || nsText.character(at: sep) == 0x3D) else {
                idx = keyMatch.keyEnd
                continue
            }
            let valStart = skipAuthWhitespace(nsText, from: sep + 1, len: len, allowNewlines: keyMatch.allowNewlines)
            guard valStart < len && !isNewline(nsText.character(at: valStart)) else {
                idx = sep + 1
                continue
            }
            if let normalized = keyMatch.normalizedKey {
                let quote = nsText.substring(with: NSRange(location: keyMatch.keyStart, length: 1))
                if result.isEmpty { result.reserveCapacity(len) }
                result += nsText.substring(with: NSRange(location: copied, length: keyMatch.keyStart - copied))
                result += "\(quote)\(normalized)\(quote)"
                copied = keyMatch.keyEnd
            }
            idx = redactAuthHeaderValue(
                nsText, valStart: valStart, allowNewlines: keyMatch.allowNewlines, result: &result, copied: &copied
            )
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func matchAuthHeaderKey(_ nsText: NSString, at pos: Int, len: Int) -> AuthKeyMatch? {
        let ch = nsText.character(at: pos)
        if ch == 0x22 || ch == 0x27 {
            return matchQuotedAuthKey(nsText, at: pos, quote: ch, len: len)
        }
        if pos > 0 && isAuthKeyWordChar(nsText.character(at: pos - 1)) { return nil }
        if matchesASCII(nsText, at: pos, literal: "proxy-authorization", len: len),
            pos + 19 == len || !isAuthKeyWordChar(nsText.character(at: pos + 19))
        {
            return AuthKeyMatch(keyStart: pos, keyEnd: pos + 19, allowNewlines: false, normalizedKey: nil)
        }
        if matchesASCII(nsText, at: pos, literal: "authorization", len: len),
            pos + 13 == len || !isAuthKeyWordChar(nsText.character(at: pos + 13))
        {
            return AuthKeyMatch(keyStart: pos, keyEnd: pos + 13, allowNewlines: false, normalizedKey: nil)
        }
        return nil
    }

    private static func matchQuotedAuthKey(
        _ nsText: NSString, at pos: Int, quote: unichar, len: Int
    ) -> AuthKeyMatch? {
        let limit = min(len, pos + 129)
        var decoded: [unichar] = []
        decoded.reserveCapacity(20)
        var sawEscape = false
        var idx = pos + 1
        while idx < limit {
            let ch = nsText.character(at: idx)
            if isNewline(ch) { return nil }
            if ch == quote {
                let key = String(utf16CodeUnits: decoded, count: decoded.count).lowercased()
                if key == "authorization" {
                    return AuthKeyMatch(
                        keyStart: pos, keyEnd: idx + 1, allowNewlines: true,
                        normalizedKey: sawEscape ? "Authorization" : nil
                    )
                }
                if key == "proxy-authorization" {
                    return AuthKeyMatch(
                        keyStart: pos, keyEnd: idx + 1, allowNewlines: true,
                        normalizedKey: sawEscape ? "Proxy-Authorization" : nil
                    )
                }
                return nil
            }
            guard decoded.count < 19 else { return nil }
            if ch == 0x5C {
                sawEscape = true
                guard let (unit, step) = decodeKeyEscape(nsText, at: idx, len: len) else { return nil }
                decoded.append(unit)
                idx += step
            } else {
                decoded.append(ch)
                idx += 1
            }
        }
        return nil
    }

    private static func decodeKeyEscape(_ nsText: NSString, at pos: Int, len: Int) -> (unichar, Int)? {
        guard pos + 1 < len else { return nil }
        let next = nsText.character(at: pos + 1)
        if next == 0x75 && pos + 5 < len, let hex = parseHex4(nsText, at: pos + 2) {
            return (hex, 6)
        }
        return (next, 2)
    }

    private static func parseHex4(_ nsText: NSString, at pos: Int) -> unichar? {
        var value: UInt32 = 0
        for offset in 0..<4 {
            let ch = nsText.character(at: pos + offset)
            let digit: UInt32
            if ch >= 0x30 && ch <= 0x39 {
                digit = UInt32(ch - 0x30)
            } else if ch >= 0x61 && ch <= 0x66 {
                digit = UInt32(ch - 0x61 + 10)
            } else if ch >= 0x41 && ch <= 0x46 {
                digit = UInt32(ch - 0x41 + 10)
            } else {
                return nil
            }
            value = (value << 4) | digit
        }
        return unichar(value)
    }

    private static func redactAuthHeaderValue(
        _ nsText: NSString, valStart: Int, allowNewlines: Bool, result: inout String, copied: inout Int
    ) -> Int {
        let len = nsText.length
        let ch = nsText.character(at: valStart)
        if ch == 0x22 || ch == 0x27 {
            return redactQuotedAuthString(nsText, quotePos: valStart, quote: ch, result: &result, copied: &copied)
        }
        if ch == 0x5B {
            return redactAuthArrayValue(
                nsText, start: valStart + 1, allowNewlines: allowNewlines, result: &result, copied: &copied
            )
        }
        var lineEnd = scanPlainAuthValueEnd(nsText, from: valStart, len: len)
        if let redacted = redactAuthValueBody(nsText, start: valStart, end: lineEnd) {
            if result.isEmpty { result.reserveCapacity(len) }
            result += nsText.substring(with: NSRange(location: copied, length: valStart - copied))
            result += redacted
            copied = lineEnd
        }
        return lineEnd
    }

    private static func scanPlainAuthValueEnd(_ nsText: NSString, from start: Int, len: Int) -> Int {
        var end = start
        while end < len {
            let ch = nsText.character(at: end)
            if isNewline(ch) {
                let fold = advanceObsFold(nsText, at: end, len: len)
                if fold > end {
                    end = fold
                    continue
                }
                break
            }
            end += 1
        }
        return end
    }

    private static func redactAuthArrayValue(
        _ nsText: NSString, start: Int, allowNewlines: Bool, result: inout String, copied: inout Int
    ) -> Int {
        let len = nsText.length
        var depth = 1
        var idx = start
        while idx < len && depth > 0 {
            let ch = nsText.character(at: idx)
            if ch == 0x5B {
                depth += 1
                idx += 1
            } else if ch == 0x5D {
                depth -= 1
                idx += 1
            } else if ch == 0x22 || ch == 0x27 {
                idx = redactQuotedAuthString(nsText, quotePos: idx, quote: ch, result: &result, copied: &copied)
            } else if isHorizSpace(ch) || ch == 0x2C {
                idx += 1
            } else if isNewline(ch) {
                let next = nextAfterArrayNewline(nsText, at: idx, len: len, allowNewlines: allowNewlines)
                if next < 0 { return idx }
                idx = next
            } else {
                idx = redactUnquotedArrayElement(nsText, from: idx, len: len, result: &result, copied: &copied)
            }
        }
        return idx
    }

    private static func nextAfterArrayNewline(_ nsText: NSString, at pos: Int, len: Int, allowNewlines: Bool) -> Int {
        if allowNewlines { return pos + 1 }
        return advanceObsFold(nsText, at: pos, len: len)
    }

    private static func redactUnquotedArrayElement(
        _ nsText: NSString, from start: Int, len: Int, result: inout String, copied: inout Int
    ) -> Int {
        var elemEnd = start
        while elemEnd < len {
            let ch = nsText.character(at: elemEnd)
            if ch == 0x2C || ch == 0x5B || ch == 0x5D || isNewline(ch) { break }
            elemEnd += 1
        }
        var trimEnd = elemEnd
        while trimEnd > start && isHorizSpace(nsText.character(at: trimEnd - 1)) { trimEnd -= 1 }
        let isNull = trimEnd - start == 4 && nsText.substring(with: NSRange(location: start, length: 4)) == "null"
        if trimEnd > start && !isNull, let redacted = redactAuthValueBody(nsText, start: start, end: trimEnd) {
            if result.isEmpty { result.reserveCapacity(len) }
            result += nsText.substring(with: NSRange(location: copied, length: start - copied))
            result += redacted
            result += nsText.substring(with: NSRange(location: trimEnd, length: elemEnd - trimEnd))
            copied = elemEnd
        }
        return elemEnd
    }

    private static func redactQuotedAuthString(
        _ nsText: NSString, quotePos: Int, quote: unichar, result: inout String, copied: inout Int
    ) -> Int {
        let len = nsText.length
        var idx = quotePos + 1
        var escaped = false
        while idx < len {
            let ch = nsText.character(at: idx)
            if isNewline(ch) || (ch == quote && !escaped) { break }
            escaped = ch == 0x5C && !escaped
            idx += 1
        }
        let innerStart = quotePos + 1
        if let redacted = redactAuthValueBody(nsText, start: innerStart, end: idx) {
            if result.isEmpty { result.reserveCapacity(len) }
            result += nsText.substring(with: NSRange(location: copied, length: innerStart - copied))
            result += redacted
            copied = idx
        }
        return idx < len && nsText.character(at: idx) == quote ? idx + 1 : idx
    }

    private static func redactAuthValueBody(_ nsText: NSString, start: Int, end: Int) -> String? {
        var idx = start
        while idx < end && isHorizSpace(nsText.character(at: idx)) { idx += 1 }
        guard idx < end else { return nil }
        for scheme in knownAuthSchemes {
            let schemeLen = scheme.utf16.count
            if idx + schemeLen < end && matchesASCII(nsText, at: idx, literal: scheme, len: end) {
                var after = idx + schemeLen
                if isHorizSpace(nsText.character(at: after)) {
                    while after < end && isHorizSpace(nsText.character(at: after)) { after += 1 }
                    if after < end {
                        return nsText.substring(with: NSRange(location: start, length: after - start)) + "[redacted]"
                    }
                }
            }
        }
        return nsText.substring(with: NSRange(location: start, length: idx - start)) + "[redacted]"
    }

    private static func redactBasicTokens(in text: String) -> String {
        guard let regex = basicTokenRegex else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var copied = 0
        for match in matches {
            let token = nsText.substring(with: match.range(at: 2))
            guard isBasicCredentialToken(token) else { continue }
            if result.isEmpty { result.reserveCapacity(text.count) }
            result += nsText.substring(with: NSRange(location: copied, length: match.range.location - copied))
            result += nsText.substring(with: match.range(at: 1))
            result += " [redacted]"
            copied = match.range.location + match.range.length
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func isBasicCredentialToken(_ token: String) -> Bool {
        guard let data = decodeCanonicalBase64(token), data.contains(0x3A) else { return false }
        if let decoded = String(data: data, encoding: .utf8) {
            let hasControl = decoded.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7F || ($0.value >= 0x80 && $0.value <= 0x9F)
            }
            if !hasControl { return true }
        }
        return !data.contains { $0 < 0x20 || ($0 >= 0x7F && $0 <= 0x9F) }
    }

    private static func decodeCanonicalBase64(_ token: String) -> Data? {
        let bytes = Array(token.utf8)
        var unpaddedLen = bytes.count
        while unpaddedLen > 0 && bytes[unpaddedLen - 1] == 0x3D { unpaddedLen -= 1 }
        let pad = bytes.count - unpaddedLen
        guard pad <= 2, pad == 0 || (bytes.count & 3) == 0 else { return nil }
        let rem = unpaddedLen & 3
        guard rem != 1, pad == 0 || rem + pad == 4 else { return nil }
        if rem == 2 && (base64ByteValue(bytes[unpaddedLen - 1]) & 0x0F) != 0 { return nil }
        if rem == 3 && (base64ByteValue(bytes[unpaddedLen - 1]) & 0x03) != 0 { return nil }
        guard let rawNormalized = String(bytes: bytes[0..<unpaddedLen], encoding: .utf8) else { return nil }
        var normalized =
            rawNormalized
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if rem == 2 { normalized += "==" } else if rem == 3 { normalized += "=" }
        return Data(base64Encoded: normalized)
    }

    private static func base64ByteValue(_ byte: UInt8) -> Int {
        if byte >= 0x41 && byte <= 0x5A { return Int(byte - 0x41) }
        if byte >= 0x61 && byte <= 0x7A { return Int(byte - 0x61 + 26) }
        if byte >= 0x30 && byte <= 0x39 { return Int(byte - 0x30 + 52) }
        if byte == 0x2B || byte == 0x2D { return 62 }
        if byte == 0x2F || byte == 0x5F { return 63 }
        return -1
    }

    private static func skipAuthWhitespace(_ nsText: NSString, from pos: Int, len: Int, allowNewlines: Bool) -> Int {
        var idx = pos
        while idx < len {
            let ch = nsText.character(at: idx)
            if isHorizSpace(ch) || (allowNewlines && isNewline(ch)) {
                idx += 1
            } else if !allowNewlines && isNewline(ch) {
                let fold = advanceObsFold(nsText, at: idx, len: len)
                if fold > idx { idx = fold } else { break }
            } else {
                break
            }
        }
        return idx
    }

    private static func advanceObsFold(_ nsText: NSString, at nlPos: Int, len: Int) -> Int {
        let afterNl =
            (nsText.character(at: nlPos) == 0x0D && nlPos + 1 < len && nsText.character(at: nlPos + 1) == 0x0A)
            ? nlPos + 2 : nlPos + 1
        guard afterNl < len && isHorizSpace(nsText.character(at: afterNl)) else { return -1 }
        var idx = afterNl
        while idx < len && isHorizSpace(nsText.character(at: idx)) { idx += 1 }
        return idx
    }

    private static func isHorizSpace(_ ch: unichar) -> Bool { ch == 0x20 || ch == 0x09 }
    private static func isNewline(_ ch: unichar) -> Bool { ch == 0x0A || ch == 0x0D }

    private static func isAuthKeyWordChar(_ ch: unichar) -> Bool {
        CoreTelemetryService.isASCIILetter(ch) || CoreTelemetryService.isASCIIDigit(ch) || ch == 0x5F || ch == 0x2D
    }

    private static func matchesASCII(_ nsText: NSString, at pos: Int, literal: String, len: Int) -> Bool {
        let litBytes = Array(literal.utf8)
        guard pos + litBytes.count <= len else { return false }
        for offset in 0..<litBytes.count {
            var actual = nsText.character(at: pos + offset)
            var expected = unichar(litBytes[offset])
            if actual >= 0x41 && actual <= 0x5A { actual += 0x20 }
            if expected >= 0x41 && expected <= 0x5A { expected += 0x20 }
            if actual != expected { return false }
        }
        return true
    }
}

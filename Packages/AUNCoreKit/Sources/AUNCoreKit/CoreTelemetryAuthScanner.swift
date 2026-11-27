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

    static let basicTokenRegex: NSRegularExpression? = try? NSRegularExpression(
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

    struct AuthScanState {
        var result = ""
        var copied = 0
        var braceMap: [Int: Int] = [:]
        var closeToOpenMap: [Int: Int] = [:]
        var memberCommaValid: [Int: Bool] = [:]
        var failedBraceBack = -1
        var failedBracketBack = -1

        mutating func appendRedacted(_ nsText: NSString, start: Int, end: Int, replacement: String) {
            if result.isEmpty { result.reserveCapacity(nsText.length) }
            result += nsText.substring(with: NSRange(location: copied, length: start - copied))
            result += replacement
            copied = end
        }
    }

    private struct AuthKeyMatch {
        let keyStart: Int
        let keyEnd: Int
        let isJsonCandidate: Bool
        let normalizedKey: String?
    }

    private static func redactAuthHeaders(in text: String) -> String {
        guard text.contains(":") || text.contains("=") else { return text }
        let nsText = text as NSString
        let len = nsText.length
        var state = AuthScanState()
        var idx = 0
        while idx < len {
            guard let keyMatch = matchAuthHeaderKey(nsText, at: idx, len: len, state: &state) else {
                idx += 1
                continue
            }
            let sep = skipAuthWhitespace(nsText, from: keyMatch.keyEnd, len: len, allowNewlines: keyMatch.isJsonCandidate)
            guard sep < len && (nsText.character(at: sep) == 0x3A || nsText.character(at: sep) == 0x3D) else {
                idx = keyMatch.keyEnd
                continue
            }
            let isJsonMember = keyMatch.isJsonCandidate && nsText.character(at: sep) == 0x3A
            let valStart = skipAuthWhitespace(nsText, from: sep + 1, len: len, allowNewlines: isJsonMember)
            guard valStart < len && !isNewline(nsText.character(at: valStart)) else {
                idx = sep + 1
                continue
            }
            if let normalized = keyMatch.normalizedKey {
                let quote = nsText.substring(with: NSRange(location: keyMatch.keyStart, length: 1))
                state.appendRedacted(
                    nsText, start: keyMatch.keyStart, end: keyMatch.keyEnd, replacement: "\(quote)\(normalized)\(quote)")
            }
            idx = redactAuthHeaderValue(nsText, valStart: valStart, isJsonMember: isJsonMember, state: &state)
        }
        guard state.copied > 0 else { return text }
        state.result += nsText.substring(from: state.copied)
        return state.result
    }

    private static func matchAuthHeaderKey(
        _ nsText: NSString, at pos: Int, len: Int, state: inout AuthScanState
    ) -> AuthKeyMatch? {
        let ch = nsText.character(at: pos)
        if ch == 0x22 || ch == 0x27 {
            return matchQuotedAuthKey(nsText, at: pos, quote: ch, state: &state)
        }
        if pos > 0 && isAuthKeyWordChar(nsText.character(at: pos - 1)) { return nil }
        if matchesASCII(nsText, at: pos, literal: "proxy-authorization", len: len),
            pos + 19 == len || !isAuthKeyWordChar(nsText.character(at: pos + 19))
        {
            return AuthKeyMatch(keyStart: pos, keyEnd: pos + 19, isJsonCandidate: false, normalizedKey: nil)
        }
        if matchesASCII(nsText, at: pos, literal: "authorization", len: len),
            pos + 13 == len || !isAuthKeyWordChar(nsText.character(at: pos + 13))
        {
            return AuthKeyMatch(keyStart: pos, keyEnd: pos + 13, isJsonCandidate: false, normalizedKey: nil)
        }
        return nil
    }

    private static func matchQuotedAuthKey(
        _ nsText: NSString, at pos: Int, quote: unichar, state: inout AuthScanState
    ) -> AuthKeyMatch? {
        let len = nsText.length
        let limit = min(len, pos + 129)
        var decoded: [unichar] = []
        decoded.reserveCapacity(20)
        var sawEscape = false
        var idx = pos + 1
        while idx < limit {
            let ch = nsText.character(at: idx)
            if ch < 0x20 { return nil }
            if ch == quote {
                let key = String(utf16CodeUnits: decoded, count: decoded.count).lowercased()
                let isJson = quote == 0x22 && isPrecededByJsonMemberDelimiter(nsText, before: pos, state: &state)
                if key == "authorization" {
                    return AuthKeyMatch(
                        keyStart: pos, keyEnd: idx + 1, isJsonCandidate: isJson,
                        normalizedKey: sawEscape ? "Authorization" : nil
                    )
                }
                if key == "proxy-authorization" {
                    return AuthKeyMatch(
                        keyStart: pos, keyEnd: idx + 1, isJsonCandidate: isJson,
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
        _ nsText: NSString, valStart: Int, isJsonMember: Bool, state: inout AuthScanState
    ) -> Int {
        let ch = nsText.character(at: valStart)
        if ch == 0x22 || ch == 0x27 {
            let afterQuote = redactQuotedAuthString(nsText, quotePos: valStart, quote: ch, state: &state)
            return redactTrailingPlainAuthContinuation(nsText, afterPos: afterQuote, isJsonMember: isJsonMember, state: &state)
        }
        if ch == 0x5B {
            let afterArray = redactAuthArrayValue(nsText, start: valStart + 1, isJsonMember: isJsonMember, state: &state)
            return redactTrailingPlainAuthContinuation(nsText, afterPos: afterArray, isJsonMember: isJsonMember, state: &state)
        }
        if ch == 0x7B, let next = redactJsonObject(nsText, from: valStart, isJsonMember: isJsonMember, state: &state) {
            return next < nsText.length
                ? redactTrailingPlainAuthContinuation(nsText, afterPos: next, isJsonMember: isJsonMember, state: &state)
                : next
        }
        if isJsonMember, let afterPrim = tryRedactJsonPrimitiveAuthValue(nsText, from: valStart, state: &state) {
            return afterPrim
        }
        return redactPlainAuthSpan(nsText, from: valStart, state: &state)
    }

    private static func tryRedactJsonPrimitiveAuthValue(
        _ nsText: NSString, from valStart: Int, state: inout AuthScanState
    ) -> Int? {
        let len = nsText.length
        var tokenEnd = valStart
        while tokenEnd < len && !isJsonPrimitiveStop(nsText.character(at: tokenEnd)) { tokenEnd += 1 }
        guard tokenEnd > valStart else { return nil }
        let token = nsText.substring(with: NSRange(location: valStart, length: tokenEnd - valStart))
        let isNull = token == "null"
        guard isNull || token == "true" || token == "false" || isJsonNumber(token) else { return nil }
        let next = skipAuthWhitespace(nsText, from: tokenEnd, len: len, allowNewlines: true)
        guard next >= len || isJsonMemberContinuationDelimiter(nsText, at: next) else { return nil }
        if !isNull {
            state.appendRedacted(nsText, start: valStart, end: tokenEnd, replacement: "\"[redacted]\"")
        }
        return tokenEnd
    }

    private static func redactPlainAuthSpan(_ nsText: NSString, from valStart: Int, state: inout AuthScanState) -> Int {
        let lineEnd = scanPlainAuthValueEnd(nsText, from: valStart, len: nsText.length)
        if let redacted = redactAuthValueBody(nsText, start: valStart, end: lineEnd) {
            state.appendRedacted(nsText, start: valStart, end: lineEnd, replacement: redacted)
        }
        return lineEnd
    }

    private static func redactTrailingPlainAuthContinuation(
        _ nsText: NSString, afterPos: Int, isJsonMember: Bool, state: inout AuthScanState
    ) -> Int {
        let tailStart = findTrailingPlainAuthStart(nsText, afterPos: afterPos, isJsonMember: isJsonMember)
        guard tailStart >= 0 else { return afterPos }
        return redactPlainAuthSpan(nsText, from: tailStart, state: &state)
    }

    private static func findTrailingPlainAuthStart(_ nsText: NSString, afterPos: Int, isJsonMember: Bool) -> Int {
        let len = nsText.length
        var pos = afterPos
        while pos < len {
            while pos < len && isHorizSpace(nsText.character(at: pos)) { pos += 1 }
            let fold = advanceObsFold(nsText, at: pos, len: len)
            if fold > pos {
                pos = fold
                continue
            }
            break
        }
        guard pos < len && !isNewline(nsText.character(at: pos)) else { return -1 }
        if isJsonMember && isJsonMemberContinuationDelimiter(nsText, at: pos) { return -1 }
        return pos
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
        _ nsText: NSString, start: Int, isJsonMember: Bool, state: inout AuthScanState
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
                idx = redactQuotedAuthString(nsText, quotePos: idx, quote: ch, state: &state)
            } else if ch == 0x7B,
                let next = redactJsonObject(nsText, from: idx, isJsonMember: isJsonMember, state: &state)
            {
                idx = next
            } else if isHorizSpace(ch) || ch == 0x2C {
                idx += 1
            } else if isNewline(ch) {
                let next = nextAfterArrayNewline(nsText, at: idx, len: len, allowNewlines: isJsonMember)
                if next < 0 { return idx }
                idx = next
            } else {
                idx = redactUnquotedArrayElement(nsText, from: idx, isJsonMember: isJsonMember, state: &state)
            }
        }
        return idx
    }

    private static func nextAfterArrayNewline(_ nsText: NSString, at pos: Int, len: Int, allowNewlines: Bool) -> Int {
        if allowNewlines { return pos + 1 }
        return advanceObsFold(nsText, at: pos, len: len)
    }

    private static func redactUnquotedArrayElement(
        _ nsText: NSString, from start: Int, isJsonMember: Bool, state: inout AuthScanState
    ) -> Int {
        let len = nsText.length
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
            let wrapped = isJsonMember ? "\"\(redacted)\"" : redacted
            let suffix = nsText.substring(with: NSRange(location: trimEnd, length: elemEnd - trimEnd))
            state.appendRedacted(nsText, start: start, end: elemEnd, replacement: wrapped + suffix)
        }
        return elemEnd
    }

    private static func redactQuotedAuthString(
        _ nsText: NSString, quotePos: Int, quote: unichar, state: inout AuthScanState
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
            state.appendRedacted(nsText, start: innerStart, end: idx, replacement: redacted)
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
}

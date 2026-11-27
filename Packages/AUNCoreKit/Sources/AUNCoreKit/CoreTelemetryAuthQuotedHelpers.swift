import Foundation

extension CoreTelemetryAuthScanner {
    static func redactEscapedTokensInBalancedQuotes(in text: String) -> String {
        guard text.contains("\"") && text.contains("\\") else { return text }
        let afterBearer = redactEscapedTokenPass(in: text, isBasic: false)
        return redactEscapedTokenPass(in: afterBearer, isBasic: true)
    }

    private static func redactEscapedTokenPass(in text: String, isBasic: Bool) -> String {
        guard let regex = isBasic ? basicTokenRegex : bearerTokenRegex else { return text }
        let nsText = text as NSString
        let spans = CoreTelemetryService.collectBalancedDoubleQuoteSpans(nsText)
        guard !spans.isEmpty else { return text }
        let keyword = isBasic ? "basic" : "bearer"
        var result = ""
        var copied = 0
        for span in spans {
            let innerStart = span.open + 1
            guard innerStart < span.close, hasBackslash(nsText, start: innerStart, end: span.close) else { continue }
            applyEscapedTokenSpan(
                nsText, range: innerStart..<span.close,
                config: (regex, keyword, isBasic),
                result: &result, copied: &copied
            )
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func hasBackslash(_ nsText: NSString, start: Int, end: Int) -> Bool {
        nsText.range(of: "\\", options: [], range: NSRange(location: start, length: end - start)).location != NSNotFound
    }

    private static func applyEscapedTokenSpan(
        _ nsText: NSString,
        range: Range<Int>,
        config: (regex: NSRegularExpression, keyword: String, isBasic: Bool),
        result: inout String,
        copied: inout Int
    ) {
        let (decoded, rawOffsets) = CoreTelemetryService.decodeQuotedSpanWithOffsets(
            nsText, start: range.lowerBound, end: range.upperBound
        )
        guard decoded.range(of: config.keyword, options: [.caseInsensitive]) != nil else { return }
        let nsDecoded = decoded as NSString
        let matches = config.regex.matches(in: decoded, options: [], range: NSRange(location: 0, length: nsDecoded.length))
        for match in matches {
            if config.isBasic && !isBasicCredentialToken(nsDecoded.substring(with: match.range(at: 2))) { continue }
            let rawStart = rawOffsets[match.range.location]
            let rawEnd = rawOffsets[match.range.location + match.range.length]
            guard rawStart >= copied else { continue }
            if result.isEmpty { result.reserveCapacity(nsText.length) }
            let scheme = nsDecoded.substring(with: match.range(at: 1))
            result += nsText.substring(with: NSRange(location: copied, length: rawStart - copied))
            result += "\(scheme) [redacted]"
            copied = rawEnd
        }
    }

    static func findBalancedJsonStringEnd(_ nsText: NSString, open: Int, len: Int) -> Int? {
        let prev = skipJsonWhitespaceBackward(nsText, from: open - 1)
        if prev >= 0 {
            let pCh = nsText.character(at: prev)
            if pCh != 0x3A && pCh != 0x3D && pCh != 0x5B && pCh != 0x2C && pCh != 0x7B { return nil }
        }
        var pos = open + 1
        var escaped = false
        while pos < len {
            let ch = nsText.character(at: pos)
            if ch == 0x0A || ch == 0x0D { return nil }
            if ch == 0x22 && !escaped {
                return isJsonStringEndBoundary(nsText, afterPos: pos + 1, len: len) ? pos : nil
            }
            escaped = ch == 0x5C && !escaped
            pos += 1
        }
        return nil
    }

    private static func isJsonStringEndBoundary(_ nsText: NSString, afterPos: Int, len: Int) -> Bool {
        guard afterPos < len else { return true }
        if CoreTelemetryService.VaultLineTracker.isWhitespace(nsText.character(at: afterPos)) { return true }
        let after = skipJsonWhitespaceForward(nsText, from: afterPos, len: len)
        guard after < len else { return true }
        let aCh = nsText.character(at: after)
        return aCh == 0x2C || aCh == 0x7D || aCh == 0x5D || aCh == 0x3A || aCh == 0x3B || aCh == 0x29
    }

    static func redactAuthHeadersInBalancedSpan(
        _ nsText: NSString, innerStart: Int, close: Int, nextDepth: Int, state: inout AuthScanState
    ) {
        guard innerStart < close && containsAuthHeaderCandidate(nsText, start: innerStart, end: close) else { return }
        let decoded: String
        let rawOffsets: [Int]?
        if hasBackslash(nsText, start: innerStart, end: close) {
            (decoded, rawOffsets) = CoreTelemetryService.decodeQuotedSpanWithOffsets(nsText, start: innerStart, end: close)
        } else {
            decoded = nsText.substring(with: NSRange(location: innerStart, length: close - innerStart))
            rawOffsets = nil
        }
        guard decoded.contains(":") || decoded.contains("=") else { return }
        var innerState = AuthScanState()
        innerState.edits = []
        scanAuthHeaders(decoded as NSString, maxDepth: nextDepth, state: &innerState)
        for (eStart, eEnd, eRepl) in innerState.edits ?? [] {
            let rawStart = rawOffsets?[eStart] ?? (innerStart + eStart)
            let rawEnd = rawOffsets?[eEnd] ?? (innerStart + eEnd)
            state.appendRedacted(nsText, start: rawStart, end: rawEnd, replacement: escapeJsonStringContent(eRepl))
        }
    }

    private static func containsAuthHeaderCandidate(_ nsText: NSString, start: Int, end: Int) -> Bool {
        var idx = start
        while idx < end {
            let ch = nsText.character(at: idx)
            if ch == 0x3A || ch == 0x3D { return true }
            if ch == 0x5C && idx + 5 < end && nsText.character(at: idx + 1) == 0x75 { return true }
            idx += 1
        }
        return false
    }

    private static func escapeJsonStringContent(_ text: String) -> String {
        let nsText = text as NSString
        let len = nsText.length
        var out = ""
        var copied = 0
        for idx in 0..<len {
            let ch = nsText.character(at: idx)
            if ch == 0x22 || ch == 0x5C || ch < 0x20 {
                if out.isEmpty { out.reserveCapacity(len + 8) }
                out += nsText.substring(with: NSRange(location: copied, length: idx - copied))
                out += jsonEscapeUnit(ch)
                copied = idx + 1
            }
        }
        guard copied > 0 else { return text }
        out += nsText.substring(from: copied)
        return out
    }

    private static func jsonEscapeUnit(_ ch: unichar) -> String {
        switch ch {
        case 0x22: return "\\\""
        case 0x5C: return "\\\\"
        case 0x08: return "\\b"
        case 0x0C: return "\\f"
        case 0x0A: return "\\n"
        case 0x0D: return "\\r"
        case 0x09: return "\\t"
        default:
            let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
            let v = Int(ch)
            return "\\u\(digits[(v >> 12) & 0xF])\(digits[(v >> 8) & 0xF])\(digits[(v >> 4) & 0xF])\(digits[v & 0xF])"
        }
    }

    static func redactUnquotedArrayElement(
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

    static func redactQuotedAuthString(
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

    static func redactAuthValueBody(_ nsText: NSString, start: Int, end: Int) -> String? {
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

import Foundation

extension CoreTelemetryAuthScanner {
    static func matchAuthSeparator(_ nsText: NSString, at pos: Int, len: Int) -> (Int, Bool)? {
        guard pos < len else { return nil }
        let ch = nsText.character(at: pos)
        if ch == 0x3A || ch == 0x3D { return (1, ch == 0x3A) }
        guard
            ch == 0x5C && pos + 5 < len && nsText.character(at: pos + 1) == 0x75
                && !CoreTelemetryService.VaultLineTracker.isPrecededByOddBackslashes(nsText, at: pos, minPos: 0),
            let code = CoreTelemetryService.parseHex4(nsText, pos: pos + 2),
            code == 0x3A || code == 0x3D
        else { return nil }
        return (6, code == 0x3A)
    }

    static func redactBearerTokens(in text: String) -> String {
        guard text.range(of: "bearer", options: [.caseInsensitive]) != nil else { return text }
        let nsText = text as NSString
        let ranges = findBearerTokenRanges(nsText, allowLiteralQuoted: true, requireClosingLiteralQuote: true)
        guard !ranges.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var copied = 0
        for (start, end, redactedOnly) in ranges {
            result += nsText.substring(with: NSRange(location: copied, length: start - copied))
            if redactedOnly {
                result += "[redacted]"
            } else {
                result += nsText.substring(with: NSRange(location: start, length: 6)) + " [redacted]"
            }
            copied = end
        }
        result += nsText.substring(from: copied)
        return result
    }

    private static func escapedDoubleQuoteLen(_ nsText: NSString, at pos: Int, len: Int) -> Int {
        if pos + 1 < len && nsText.character(at: pos) == 0x5C && nsText.character(at: pos + 1) == 0x22 { return 2 }
        if pos + 5 < len && nsText.character(at: pos) == 0x5C && nsText.character(at: pos + 1) == 0x75,
            let code = CoreTelemetryService.parseHex4(nsText, pos: pos + 2), code == 0x22
        {
            return 6
        }
        return 0
    }

    private static func findBearerTokenRanges(
        _ nsText: NSString, allowLiteralQuoted: Bool, requireClosingLiteralQuote: Bool
    ) -> [(Int, Int, Bool)] {
        let len = nsText.length
        var ranges: [(Int, Int, Bool)] = []
        var inEscapedQuote = false
        var idx = 0
        while idx < len {
            if let nextIdx = stepBearerQuoteState(nsText, at: idx, len: len, inEscapedQuote: &inEscapedQuote) {
                idx = nextIdx
                continue
            }
            guard matchesBearerPrefix(nsText, at: idx, len: len) else {
                idx += 1
                continue
            }
            var wsEnd = idx + 6
            while wsEnd < len && CoreTelemetryService.VaultLineTracker.isWhitespace(nsText.character(at: wsEnd)) {
                wsEnd += 1
            }
            guard wsEnd < len else { break }
            if !inEscapedQuote,
                let nextIdx = tryScanQuotedBearerToken(
                    nsText, wsEnd: wsEnd, len: len, allowLiteralQuoted: allowLiteralQuoted,
                    requireClosingLiteralQuote: requireClosingLiteralQuote, ranges: &ranges)
            {
                idx = nextIdx
                continue
            }
            if isRedactedBearerPlaceholder(nsText, at: wsEnd, len: len, stopAtEscapedQuote: inEscapedQuote) {
                idx = wsEnd + 10
                continue
            }
            let tokEnd = scanBearerTokenEnd(nsText, from: wsEnd, len: len, stopAtEscapedQuote: inEscapedQuote)
            if tokEnd > wsEnd {
                ranges.append((idx, tokEnd, false))
                idx = tokEnd
            } else {
                idx = wsEnd
            }
        }
        return ranges
    }

    // swiftlint:disable:next function_parameter_count
    private static func tryScanQuotedBearerToken(
        _ nsText: NSString,
        wsEnd: Int,
        len: Int,
        allowLiteralQuoted: Bool,
        requireClosingLiteralQuote: Bool,
        ranges: inout [(Int, Int, Bool)]
    ) -> Int? {
        let wsCh = nsText.character(at: wsEnd)
        let isLiteralQuote = allowLiteralQuoted && (wsCh == 0x22 || wsCh == 0x27)
        let openLen = isLiteralQuote ? 1 : escapedDoubleQuoteLen(nsText, at: wsEnd, len: len)
        guard openLen > 0 else { return nil }
        let innerStart = wsEnd + openLen
        let stopEsc = openLen > 1
        if isRedactedBearerPlaceholder(nsText, at: innerStart, len: len, stopAtEscapedQuote: stopEsc) {
            return innerStart + 10
        }
        let innerEnd = scanBearerTokenEnd(nsText, from: innerStart, len: len, stopAtEscapedQuote: stopEsc)
        let closeLen =
            openLen == 1
            ? (innerEnd < len && nsText.character(at: innerEnd) == wsCh ? 1 : 0)
            : escapedDoubleQuoteLen(nsText, at: innerEnd, len: len)
        if innerEnd > innerStart && (closeLen > 0 || (openLen == 1 && !requireClosingLiteralQuote)) {
            ranges.append((innerStart, innerEnd, true))
            return innerEnd + closeLen
        }
        return innerEnd == innerStart && closeLen > 0 ? innerEnd + closeLen : nil
    }

    private static func stepBearerQuoteState(
        _ nsText: NSString, at pos: Int, len: Int, inEscapedQuote: inout Bool
    ) -> Int? {
        let ch = nsText.character(at: pos)
        if ch == 0x5C && pos + 1 < len {
            let next = nsText.character(at: pos + 1)
            if next == 0x22 {
                inEscapedQuote.toggle()
                return pos + 2
            }
            if next == 0x75 && pos + 5 < len, let code = CoreTelemetryService.parseHex4(nsText, pos: pos + 2) {
                if code == 0x22 { inEscapedQuote.toggle() }
                return pos + 6
            }
            return pos + 2
        }
        if ch == 0x22 || ch == 0x0A || ch == 0x0D {
            inEscapedQuote = false
            return pos + 1
        }
        return nil
    }

    private static func matchesBearerPrefix(_ nsText: NSString, at idx: Int, len: Int) -> Bool {
        guard idx + 6 < len else { return false }
        let wordBefore = idx > 0 && isBearerWordChar(nsText.character(at: idx - 1))
        return !wordBefore && matchesASCII(nsText, at: idx, literal: "bearer", len: len)
            && CoreTelemetryService.VaultLineTracker.isWhitespace(nsText.character(at: idx + 6))
    }

    private static func isBearerWordChar(_ ch: unichar) -> Bool {
        CoreTelemetryService.isASCIIAlphaNum(ch) || ch == 0x5F
    }

    private static func isRedactedBearerPlaceholder(
        _ nsText: NSString, at pos: Int, len: Int, stopAtEscapedQuote: Bool
    ) -> Bool {
        guard pos + 10 <= len && nsText.substring(with: NSRange(location: pos, length: 10)) == "[redacted]" else {
            return false
        }
        let after = pos + 10
        guard after < len else { return true }
        let ch = nsText.character(at: after)
        if CoreTelemetryService.VaultLineTracker.isWhitespace(ch) || isBearerStopPunct(ch) { return true }
        return isBearerEscapeBoundary(nsText, at: after, len: len, stopAtEscapedQuote: stopAtEscapedQuote)
    }

    private static func isBearerEscapeBoundary(
        _ nsText: NSString, at pos: Int, len: Int, stopAtEscapedQuote: Bool
    ) -> Bool {
        guard nsText.character(at: pos) == 0x5C && pos + 1 < len else { return false }
        let esc = nsText.character(at: pos + 1)
        if esc == 0x6E || esc == 0x72 || esc == 0x74 || esc == 0x62 || esc == 0x66 { return true }
        if stopAtEscapedQuote && esc == 0x22 { return true }
        guard esc == 0x75 && pos + 5 < len, let code = CoreTelemetryService.parseHex4(nsText, pos: pos + 2) else {
            return false
        }
        return CoreTelemetryService.VaultLineTracker.isWhitespace(code) || (stopAtEscapedQuote && code == 0x22)
    }

    private static func isBearerStopPunct(_ ch: unichar) -> Bool {
        ch == 0x22 || ch == 0x27 || ch == 0x2C || ch == 0x3B || ch == 0x29 || ch == 0x5D || ch == 0x7D
    }

    private static func scanBearerTokenEnd(
        _ nsText: NSString, from start: Int, len: Int, stopAtEscapedQuote: Bool
    ) -> Int {
        var pos = start
        while pos < len {
            let ch = nsText.character(at: pos)
            if ch == 0x5C {
                if pos + 1 >= len || CoreTelemetryService.VaultLineTracker.isWhitespace(nsText.character(at: pos + 1)) {
                    pos += 1
                    break
                }
                if isBearerEscapeBoundary(nsText, at: pos, len: len, stopAtEscapedQuote: stopAtEscapedQuote) { break }
                let next = nsText.character(at: pos + 1)
                pos += (next == 0x75 && pos + 5 < len && CoreTelemetryService.parseHex4(nsText, pos: pos + 2) != nil) ? 6 : 2
                continue
            }
            if CoreTelemetryService.VaultLineTracker.isWhitespace(ch) || isBearerStopPunct(ch) { break }
            pos += 1
        }
        return pos
    }

    static func redactEscapedBearerInBalancedQuotes(in text: String) -> String {
        guard text.contains("\"") && text.contains("\\") else { return text }
        let nsText = text as NSString
        let spans = CoreTelemetryService.collectBalancedDoubleQuoteSpans(nsText)
        guard !spans.isEmpty else { return text }
        var result = ""
        var copied = 0
        for span in spans {
            let innerStart = span.open + 1
            guard innerStart < span.close, hasBackslash(nsText, start: innerStart, end: span.close) else { continue }
            let (decoded, rawOffsets) = CoreTelemetryService.decodeQuotedSpanWithOffsets(
                nsText, start: innerStart, end: span.close)
            guard decoded.range(of: "bearer", options: [.caseInsensitive]) != nil else { continue }
            let nsDecoded = decoded as NSString
            for (mStart, mEnd, redactedOnly) in findBearerTokenRanges(
                nsDecoded, allowLiteralQuoted: true, requireClosingLiteralQuote: false)
            {
                let rawStart = rawOffsets[mStart]
                let rawEnd = rawOffsets[mEnd]
                guard rawStart >= copied else { continue }
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copied, length: rawStart - copied))
                if redactedOnly {
                    result += "[redacted]"
                } else {
                    result += nsDecoded.substring(with: NSRange(location: mStart, length: 6)) + " [redacted]"
                }
                copied = rawEnd
            }
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    static func redactEscapedBasicInBalancedQuotes(in text: String) -> String {
        guard text.contains("\"") && text.contains("\\"), let regex = basicTokenRegex else { return text }
        let nsText = text as NSString
        let spans = CoreTelemetryService.collectBalancedDoubleQuoteSpans(nsText)
        guard !spans.isEmpty else { return text }
        var result = ""
        var copied = 0
        for span in spans {
            let innerStart = span.open + 1
            guard innerStart < span.close, hasBackslash(nsText, start: innerStart, end: span.close) else { continue }
            applyEscapedBasicSpan(nsText, range: innerStart..<span.close, regex: regex, result: &result, copied: &copied)
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func hasBackslash(_ nsText: NSString, start: Int, end: Int) -> Bool {
        nsText.range(of: "\\", options: [], range: NSRange(location: start, length: end - start)).location != NSNotFound
    }

    private static func applyEscapedBasicSpan(
        _ nsText: NSString,
        range: Range<Int>,
        regex: NSRegularExpression,
        result: inout String,
        copied: inout Int
    ) {
        let (decoded, rawOffsets) = CoreTelemetryService.decodeQuotedSpanWithOffsets(
            nsText, start: range.lowerBound, end: range.upperBound
        )
        guard decoded.range(of: "basic", options: [.caseInsensitive]) != nil else { return }
        let nsDecoded = decoded as NSString
        let matches = regex.matches(in: decoded, options: [], range: NSRange(location: 0, length: nsDecoded.length))
        for match in matches {
            let quotedRange = match.range(at: 3)
            let isQuoted = quotedRange.location != NSNotFound
            let tokenRange = isQuoted ? quotedRange : match.range(at: 5)
            guard tokenRange.location != NSNotFound else { continue }
            if !isBasicCredentialToken(nsDecoded.substring(with: tokenRange)) { continue }
            let targetRange = isQuoted ? tokenRange : match.range
            let rawStart = rawOffsets[targetRange.location]
            let rawEnd = rawOffsets[targetRange.location + targetRange.length]
            guard rawStart >= copied else { continue }
            if result.isEmpty { result.reserveCapacity(nsText.length) }
            result += nsText.substring(with: NSRange(location: copied, length: rawStart - copied))
            result += isQuoted ? "[redacted]" : "\(nsDecoded.substring(with: match.range(at: 1))) [redacted]"
            copied = rawEnd
        }
    }

    static func isJsonStringStartBoundary(_ nsText: NSString, open: Int) -> Bool {
        let prev = skipJsonWhitespaceBackward(nsText, from: open - 1)
        guard prev >= 0 else { return true }
        let pCh = nsText.character(at: prev)
        return pCh == 0x3A || pCh == 0x3D || pCh == 0x5B || pCh == 0x2C || pCh == 0x7B || pCh == 0x28
    }

    static func findDoubleQuotedSpanEnd(_ nsText: NSString, open: Int, len: Int) -> Int? {
        var pos = open + 1
        var escaped = false
        while pos < len {
            let ch = nsText.character(at: pos)
            if ch == 0x0A || ch == 0x0D { return nil }
            if ch == 0x22 && !escaped { return pos }
            escaped = ch == 0x5C && !escaped
            pos += 1
        }
        return nil
    }

    static func redactAuthHeadersInBalancedSpan(
        _ nsText: NSString, innerStart: Int, close: Int, nextDepth: Int, state: inout AuthScanState
    ) -> Bool {
        guard innerStart < close && containsAuthHeaderCandidate(nsText, start: innerStart, end: close) else {
            return false
        }
        let decoded: String
        let rawOffsets: [Int]?
        if hasBackslash(nsText, start: innerStart, end: close) {
            (decoded, rawOffsets) = CoreTelemetryService.decodeQuotedSpanWithOffsets(nsText, start: innerStart, end: close)
        } else {
            decoded = nsText.substring(with: NSRange(location: innerStart, length: close - innerStart))
            rawOffsets = nil
        }
        guard decoded.contains(":") || decoded.contains("=") || (decoded.contains("[") && decoded.contains(",")) else {
            return false
        }
        var innerState = AuthScanState()
        innerState.edits = []
        scanAuthHeaders(decoded as NSString, maxDepth: nextDepth, state: &innerState)
        let edits = innerState.edits ?? []
        guard !edits.isEmpty else { return false }
        for (eStart, eEnd, eRepl) in edits {
            let rawStart = rawOffsets?[eStart] ?? (innerStart + eStart)
            let rawEnd = rawOffsets?[eEnd] ?? (innerStart + eEnd)
            state.appendRedacted(nsText, start: rawStart, end: rawEnd, replacement: escapeJsonStringContent(eRepl))
        }
        return true
    }

    private static func containsAuthHeaderCandidate(_ nsText: NSString, start: Int, end: Int) -> Bool {
        var idx = start
        while idx < end {
            let ch = nsText.character(at: idx)
            if ch == 0x3A || ch == 0x3D || ch == 0x5B { return true }
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

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
        let ranges = findBearerTokenRanges(nsText, inDecodedSpan: false)
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

    private struct BearerQuoteFlags {
        let inEscapedQuote: Bool
        let inLiteralDoubleQuote: Bool
        let inDecodedSpan: Bool
    }

    private static func findBearerTokenRanges(_ nsText: NSString, inDecodedSpan: Bool) -> [(Int, Int, Bool)] {
        let len = nsText.length
        var ranges: [(Int, Int, Bool)] = []
        var inEscapedQuote = false
        var inLiteralDoubleQuote = false
        var idx = 0
        while idx < len {
            if let nextIdx = stepBearerQuoteState(
                nsText, at: idx, len: len, inEscapedQuote: &inEscapedQuote, inLiteralDoubleQuote: &inLiteralDoubleQuote)
            {
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
            let flags = BearerQuoteFlags(
                inEscapedQuote: inEscapedQuote,
                inLiteralDoubleQuote: inLiteralDoubleQuote,
                inDecodedSpan: inDecodedSpan
            )
            if let nextIdx = stepRepeatedBearerOrBasic(
                nsText, prefixStart: idx, wsEnd: wsEnd, len: len, flags: flags, ranges: &ranges)
            {
                idx = nextIdx
                continue
            }
            if !inEscapedQuote,
                let nextIdx = tryScanQuotedBearerToken(nsText, wsEnd: wsEnd, len: len, flags: flags, ranges: &ranges)
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

    private static func openingBearerQuoteLen(
        _ nsText: NSString, at pos: Int, wsCh: unichar, len: Int, flags: BearerQuoteFlags
    ) -> Int {
        guard !flags.inEscapedQuote else { return 0 }
        if wsCh == 0x22 { return !flags.inLiteralDoubleQuote || flags.inDecodedSpan ? 1 : 0 }
        if wsCh == 0x27 { return 1 }
        return escapedDoubleQuoteLen(nsText, at: pos, len: len)
    }

    private static func skipHorizontalBearerSpaces(_ nsText: NSString, from pos: Int, len: Int, allowEscaped: Bool) -> Int {
        var p = pos
        while p < len {
            let ch = nsText.character(at: p)
            if CoreTelemetryService.VaultLineTracker.isWhitespace(ch) && ch != 0x0A && ch != 0x0D {
                p += 1
                continue
            }
            if allowEscaped && ch == 0x5C && p + 1 < len {
                let next = nsText.character(at: p + 1)
                if next == 0x74 {
                    p += 2
                    continue
                }
                if next == 0x75 && p + 5 < len, let code = CoreTelemetryService.parseHex4(nsText, pos: p + 2),
                    CoreTelemetryService.VaultLineTracker.isWhitespace(code), code != 0x0A, code != 0x0D
                {
                    p += 6
                    continue
                }
            }
            break
        }
        return p
    }

    private static func isEscapedNewlineAt(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        guard pos + 1 < len && nsText.character(at: pos) == 0x5C else { return false }
        let esc = nsText.character(at: pos + 1)
        if esc == 0x6E || esc == 0x72 { return true }
        guard esc == 0x75 && pos + 5 < len, let code = CoreTelemetryService.parseHex4(nsText, pos: pos + 2) else {
            return false
        }
        return code == 0x0A || code == 0x0D
    }

    private static func resolveQuotedBearerEnd(
        _ nsText: NSString, innerEnd: Int, len: Int, openLen: Int, openCh: unichar
    ) -> Int? {
        let tail = skipHorizontalBearerSpaces(nsText, from: innerEnd, len: len, allowEscaped: openLen > 1)
        let closeLen =
            openLen == 1
            ? (tail < len && nsText.character(at: tail) == openCh ? 1 : 0)
            : escapedDoubleQuoteLen(nsText, at: tail, len: len)
        if closeLen > 0 { return tail + closeLen }
        if tail >= len || nsText.character(at: tail) == 0x0A || nsText.character(at: tail) == 0x0D
            || (openLen > 1 && isEscapedNewlineAt(nsText, at: tail, len: len))
        {
            return innerEnd
        }
        return nil
    }

    private static func tryScanQuotedBearerToken(
        _ nsText: NSString,
        wsEnd: Int,
        len: Int,
        flags: BearerQuoteFlags,
        ranges: inout [(Int, Int, Bool)]
    ) -> Int? {
        let wsCh = nsText.character(at: wsEnd)
        let openLen = openingBearerQuoteLen(nsText, at: wsEnd, wsCh: wsCh, len: len, flags: flags)
        guard openLen > 0 else { return nil }
        let innerStart = skipHorizontalBearerSpaces(nsText, from: wsEnd + openLen, len: len, allowEscaped: openLen > 1)
        let stopEsc = openLen > 1
        if isRedactedBearerPlaceholder(nsText, at: innerStart, len: len, stopAtEscapedQuote: stopEsc) {
            return innerStart + 10
        }
        let innerEnd = scanBearerTokenEnd(nsText, from: innerStart, len: len, stopAtEscapedQuote: stopEsc)
        if let afterEnd = resolveQuotedBearerEnd(nsText, innerEnd: innerEnd, len: len, openLen: openLen, openCh: wsCh) {
            if innerEnd > innerStart { ranges.append((innerStart, innerEnd, true)) }
            return afterEnd
        }
        return wsEnd
    }

    private static func stepBearerQuoteState(
        _ nsText: NSString, at pos: Int, len: Int, inEscapedQuote: inout Bool, inLiteralDoubleQuote: inout Bool
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
        if ch == 0x22 {
            inEscapedQuote = false
            inLiteralDoubleQuote.toggle()
            return pos + 1
        }
        if ch == 0x0A || ch == 0x0D {
            inEscapedQuote = false
            inLiteralDoubleQuote = false
            return pos + 1
        }
        return nil
    }

    // swiftlint:disable:next function_parameter_count
    private static func stepRepeatedBearerOrBasic(
        _ nsText: NSString,
        prefixStart: Int,
        wsEnd: Int,
        len: Int,
        flags: BearerQuoteFlags,
        ranges: inout [(Int, Int, Bool)]
    ) -> Int? {
        if matchesBearerAt(nsText, at: wsEnd, len: len) {
            var prevBearer = prefixStart
            var lastBearer = wsEnd
            var afterWs = wsEnd
            while true {
                var nextWs = lastBearer + 6
                while nextWs < len && CoreTelemetryService.VaultLineTracker.isWhitespace(nsText.character(at: nextWs)) {
                    nextWs += 1
                }
                if nextWs < len && matchesBearerAt(nsText, at: nextWs, len: len) {
                    prevBearer = lastBearer
                    lastBearer = nextWs
                } else {
                    afterWs = nextWs
                    break
                }
            }
            if afterWs < len
                && (hasRedactedBasicAt(nsText, at: afterWs, len: len)
                    || hasBearerTokenAt(nsText, at: afterWs, len: len, flags: flags))
            {
                return lastBearer
            }
            ranges.append((prevBearer, lastBearer + 6, false))
            return lastBearer + 6
        }
        return hasRedactedBasicAt(nsText, at: wsEnd, len: len) ? wsEnd : nil
    }

    private static func matchesBearerAt(_ nsText: NSString, at idx: Int, len: Int) -> Bool {
        idx + 6 < len && matchesASCII(nsText, at: idx, literal: "bearer", len: len)
            && CoreTelemetryService.VaultLineTracker.isWhitespace(nsText.character(at: idx + 6))
    }

    private static func hasBearerTokenAt(
        _ nsText: NSString,
        at pos: Int,
        len: Int,
        flags: BearerQuoteFlags
    ) -> Bool {
        guard pos < len else { return false }
        let wsCh = nsText.character(at: pos)
        let openLen = openingBearerQuoteLen(nsText, at: pos, wsCh: wsCh, len: len, flags: flags)
        if openLen > 0 {
            let innerStart = skipHorizontalBearerSpaces(nsText, from: pos + openLen, len: len, allowEscaped: openLen > 1)
            let stopEsc = openLen > 1
            if isRedactedBearerPlaceholder(nsText, at: innerStart, len: len, stopAtEscapedQuote: stopEsc) { return true }
            let innerEnd = scanBearerTokenEnd(nsText, from: innerStart, len: len, stopAtEscapedQuote: stopEsc)
            return innerEnd > innerStart
                && resolveQuotedBearerEnd(nsText, innerEnd: innerEnd, len: len, openLen: openLen, openCh: wsCh) != nil
        }
        return isRedactedBearerPlaceholder(nsText, at: pos, len: len, stopAtEscapedQuote: flags.inEscapedQuote)
            || scanBearerTokenEnd(nsText, from: pos, len: len, stopAtEscapedQuote: flags.inEscapedQuote) > pos
    }

    private static func hasRedactedBasicAt(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        guard pos + 5 < len, matchesASCII(nsText, at: pos, literal: "basic", len: len),
            CoreTelemetryService.VaultLineTracker.isWhitespace(nsText.character(at: pos + 5))
        else { return false }
        var p = pos + 5
        while p < len && CoreTelemetryService.VaultLineTracker.isWhitespace(nsText.character(at: p)) { p += 1 }
        guard p < len else { return false }
        let openCh = nsText.character(at: p)
        let openLen = (openCh == 0x22 || openCh == 0x27) ? 1 : escapedDoubleQuoteLen(nsText, at: p, len: len)
        return isRedactedBearerPlaceholder(nsText, at: p + openLen, len: len, stopAtEscapedQuote: openLen > 1)
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
                if !stopAtEscapedQuote {
                    let escQ = escapedDoubleQuoteLen(nsText, at: pos, len: len)
                    if escQ > 0 {
                        let afterQ = pos + escQ
                        if afterQ >= len
                            || CoreTelemetryService.VaultLineTracker.isWhitespace(nsText.character(at: afterQ))
                            || isBearerStopPunct(nsText.character(at: afterQ))
                            || isBearerEscapeBoundary(nsText, at: afterQ, len: len, stopAtEscapedQuote: true)
                        {
                            break
                        }
                    }
                }
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
            for (mStart, mEnd, redactedOnly) in findBearerTokenRanges(nsDecoded, inDecodedSpan: true) {
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
        let decLen = nsDecoded.length
        var pos = 0
        while pos < decLen {
            guard let match = regex.firstMatch(in: decoded, options: [], range: NSRange(location: pos, length: decLen - pos))
            else { break }
            let quotedRange = match.range(at: 3)
            let isQuoted = quotedRange.location != NSNotFound
            let tokenRange = isQuoted ? quotedRange : match.range(at: 5)
            let openRange = match.range(at: 2)
            let closeRange = match.range(at: 4)
            let openQ = isQuoted && openRange.location != NSNotFound ? nsDecoded.substring(with: openRange) : ""
            let closeQ = isQuoted && closeRange.location != NSNotFound ? nsDecoded.substring(with: closeRange) : ""
            guard tokenRange.location != NSNotFound,
                !isQuoted || areBasicQuotesCompatible(openQ, closeQ),
                isBasicCredentialToken(nsDecoded.substring(with: tokenRange))
            else {
                pos = match.range.location + 5
                continue
            }
            let targetRange = isQuoted ? tokenRange : match.range
            let rawStart = rawOffsets[targetRange.location]
            let rawEnd = rawOffsets[targetRange.location + targetRange.length]
            if rawStart >= copied {
                if result.isEmpty { result.reserveCapacity(nsText.length) }
                result += nsText.substring(with: NSRange(location: copied, length: rawStart - copied))
                result += isQuoted ? "[redacted]" : "\(nsDecoded.substring(with: match.range(at: 1))) [redacted]"
                copied = rawEnd
            }
            pos = match.range.location + match.range.length
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
}

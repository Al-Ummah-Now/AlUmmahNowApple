import Foundation

extension CoreTelemetryService {
    private struct QuotedPathSpan {
        let open: Int
        let close: Int
        let stopPos: Int
    }

    private struct QuotedScanStep {
        let found: Int
        let nextPos: Int
    }

    private struct DecodedJsonChar {
        let ch: unichar
        let len: Int
    }

    static func redactDoubleQuotedLocalPaths(in text: String) -> String {
        guard text.contains("\"") else { return text }
        let nsText = text as NSString
        let len = nsText.length
        var result = ""
        var copied = 0
        var idx = 0
        while idx < len {
            if nsText.character(at: idx) != 0x22 || isOddBackslashesBefore(nsText, at: idx, minPos: copied) {
                idx += 1
                continue
            }
            let span = findDoubleQuotedPathEnd(nsText, open: idx, len: len)
            if span.close < 0 {
                idx = span.stopPos + 1
                continue
            }
            redactQuotedNonVaultSegments(nsText, start: idx + 1, close: span.close, result: &result, copied: &copied)
            idx = span.close + 1
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    static func replaceOutsideBalancedDoubleQuotes(
        in text: String, regex: NSRegularExpression, template: String
    ) -> String {
        guard text.contains("\"") else {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
        }
        let nsText = text as NSString
        let spans = collectBalancedDoubleQuoteSpans(nsText)
        guard !spans.isEmpty else {
            let range = NSRange(location: 0, length: nsText.length)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
        }
        return applyRegexOutsideSpans(nsText, regex: regex, template: template, spans: spans)
    }

    static func replaceKeywordAssignedPaths(in text: String, regex: NSRegularExpression) -> String {
        let nsText = text as NSString
        let spans = text.contains("\"") ? collectBalancedDoubleQuoteSpans(nsText) : []
        if spans.isEmpty {
            let range = NSRange(location: 0, length: nsText.length)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1[redacted-path]")
        }
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var copied = 0
        var spanIdx = 0
        for match in matches {
            let pos = match.range.location
            while spanIdx < spans.count && spans[spanIdx].close <= pos { spanIdx += 1 }
            let end = match.range.location + match.range.length
            let clampedEnd =
                (spanIdx < spans.count && spans[spanIdx].open < pos && pos < spans[spanIdx].close
                    && end > spans[spanIdx].close)
                ? spans[spanIdx].close
                : end
            result += nsText.substring(with: NSRange(location: copied, length: pos - copied))
            result += nsText.substring(with: match.range(at: 1))
            result += "[redacted-path]"
            copied = clampedEnd
        }
        result += nsText.substring(from: copied)
        return result
    }

    private static func applyRegexOutsideSpans(
        _ nsText: NSString, regex: NSRegularExpression, template: String, spans: [QuotedPathSpan]
    ) -> String {
        let matches = regex.matches(in: nsText as String, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return nsText as String }
        let hasPrefix = template.hasPrefix("$1")
        var result = ""
        result.reserveCapacity(nsText.length)
        var copied = 0
        var spanIdx = 0
        for match in matches {
            let checkPos = matchContentCheckPos(nsText, match: match, hasPrefix: hasPrefix)
            while spanIdx < spans.count && spans[spanIdx].close <= checkPos { spanIdx += 1 }
            if spanIdx < spans.count && spans[spanIdx].open < checkPos && checkPos < spans[spanIdx].close {
                continue
            }
            result += nsText.substring(with: NSRange(location: copied, length: match.range.location - copied))
            if hasPrefix && match.numberOfRanges > 1 { result += nsText.substring(with: match.range(at: 1)) }
            result += "[redacted-path]"
            copied = match.range.location + match.range.length
        }
        guard copied > 0 else { return nsText as String }
        result += nsText.substring(from: copied)
        return result
    }

    private static func matchContentCheckPos(_ nsText: NSString, match: NSTextCheckingResult, hasPrefix: Bool) -> Int {
        if hasPrefix && match.numberOfRanges > 1 {
            let g1 = match.range(at: 1)
            return g1.location + g1.length
        }
        let loc = match.range.location
        let ch = nsText.character(at: loc)
        return (ch == 0x22 && loc + 1 < nsText.length) ? loc + 1 : loc
    }

    private static func collectBalancedDoubleQuoteSpans(_ nsText: NSString) -> [QuotedPathSpan] {
        var spans: [QuotedPathSpan] = []
        let len = nsText.length
        var idx = 0
        while idx < len {
            if nsText.character(at: idx) != 0x22 || isOddBackslashesBefore(nsText, at: idx, minPos: 0) {
                idx += 1
                continue
            }
            let span = findDoubleQuotedPathEnd(nsText, open: idx, len: len)
            if span.close < 0 {
                idx = span.stopPos + 1
                continue
            }
            spans.append(span)
            idx = span.close + 1
        }
        return spans
    }

    private static func redactQuotedNonVaultSegments(
        _ nsText: NSString, start: Int, close: Int, result: inout String, copied: inout Int
    ) {
        var segStart = start
        while segStart < close {
            let vaultRange = nsText.range(
                of: "\u{001E}", options: [], range: NSRange(location: segStart, length: close - segStart)
            )
            let segEnd = vaultRange.location != NSNotFound ? vaultRange.location : close
            var pathPos = segStart < segEnd ? findLocalPathStartInQuoted(nsText, start: segStart, end: segEnd) : -1
            if pathPos >= 0 {
                if pathPos > segStart && isOddBackslashesBefore(nsText, at: pathPos, minPos: segStart) { pathPos -= 1 }
                var redactEnd = segEnd
                if vaultRange.location != NSNotFound {
                    while redactEnd > pathPos && isHorizontalSpace(nsText.character(at: redactEnd - 1)) { redactEnd -= 1 }
                }
                if result.isEmpty { result.reserveCapacity(nsText.length) }
                result += nsText.substring(with: NSRange(location: copied, length: pathPos - copied))
                result += "[redacted-path]"
                copied = redactEnd
            }
            guard vaultRange.location != NSNotFound else { break }
            let afterVault = vaultRange.location + 1
            let endRange = nsText.range(
                of: "\u{001F}", options: [], range: NSRange(location: afterVault, length: close - afterVault)
            )
            guard endRange.location != NSNotFound else { break }
            segStart = endRange.location + 1
        }
    }

    private static func isOddBackslashesBefore(_ nsText: NSString, at pos: Int, minPos: Int) -> Bool {
        var bs = 0
        while pos - 1 - bs >= minPos && nsText.character(at: pos - 1 - bs) == 0x5C { bs += 1 }
        return (bs & 1) == 1
    }

    private static func findDoubleQuotedPathEnd(_ nsText: NSString, open: Int, len: Int) -> QuotedPathSpan {
        var escaped = false
        var pos = open + 1
        while pos < len {
            let ch = nsText.character(at: pos)
            if ch == 0x0D || ch == 0x0A {
                return QuotedPathSpan(open: open, close: -1, stopPos: pos)
            }
            if ch == 0x1F {
                escaped = false
            } else if ch == 0x22 && !escaped {
                return QuotedPathSpan(open: open, close: pos, stopPos: pos)
            } else {
                escaped = ch == 0x5C && !escaped
            }
            pos += 1
        }
        return QuotedPathSpan(open: open, close: -1, stopPos: len)
    }

    private static func decodeJsonCharAt(_ nsText: NSString, pos: Int, end: Int) -> DecodedJsonChar {
        let ch = nsText.character(at: pos)
        guard ch == 0x5C && pos + 1 < end else { return DecodedJsonChar(ch: ch, len: 1) }
        let next = nsText.character(at: pos + 1)
        if let mapped = simpleJsonEscape(next) { return DecodedJsonChar(ch: mapped, len: 2) }
        if next == 0x75 && pos + 5 < end, let code = parseHex4(nsText, pos: pos + 2) {
            return DecodedJsonChar(ch: code, len: 6)
        }
        return DecodedJsonChar(ch: ch, len: 1)
    }

    private static func simpleJsonEscape(_ ch: unichar) -> unichar? {
        switch ch {
        case 0x22: return 0x22
        case 0x2F: return 0x2F
        case 0x5C: return 0x5C
        case 0x62: return 0x08
        case 0x66: return 0x0C
        case 0x6E: return 0x0A
        case 0x72: return 0x0D
        case 0x74: return 0x09
        default: return nil
        }
    }

    private static func parseHex4(_ nsText: NSString, pos: Int) -> unichar? {
        var val: UInt32 = 0
        for offset in 0..<4 {
            let ch = nsText.character(at: pos + offset)
            guard let digit = hexDigitValue(ch) else { return nil }
            val = (val << 4) | digit
        }
        return unichar(val)
    }

    private static func hexDigitValue(_ ch: unichar) -> UInt32? {
        if ch >= 0x30 && ch <= 0x39 { return UInt32(ch - 0x30) }
        if ch >= 0x61 && ch <= 0x66 { return UInt32(10 + ch - 0x61) }
        if ch >= 0x41 && ch <= 0x46 { return UInt32(10 + ch - 0x41) }
        return nil
    }

    private static func findLocalPathStartInQuoted(_ nsText: NSString, start: Int, end: Int) -> Int {
        var tokenStart = -1
        var pos = start
        while pos < end {
            let step = stepQuotedPathScanner(nsText, pos: pos, end: end, tokenStart: &tokenStart)
            if step.found >= 0 { return step.found }
            pos = step.nextPos
        }
        return -1
    }

    private static func stepQuotedPathScanner(
        _ nsText: NSString, pos: Int, end: Int, tokenStart: inout Int
    ) -> QuotedScanStep {
        let dec0 = decodeJsonCharAt(nsText, pos: pos, end: end)
        if let driveAfter = matchDecodedWindowsDrive(nsText, pos: pos, end: end, dec0: dec0) {
            return checkTrailingNonWS(nsText, matchPos: pos, afterPos: driveAfter, end: end, tokenStart: &tokenStart)
        }
        if dec0.ch == 0x2F {
            return checkSlashRun(nsText, pos: pos, afterPos: pos + dec0.len, end: end, tokenStart: &tokenStart)
        }
        if tokenStart < 0, let prefixAfter = matchDecodedHomeOrUnc(nsText, pos: pos, end: end, dec0: dec0) {
            return checkTrailingNonWS(nsText, matchPos: pos, afterPos: prefixAfter, end: end, tokenStart: &tokenStart)
        }
        return stepPlainQuotedChar(nsText, pos: pos, end: end, dec0: dec0, tokenStart: &tokenStart)
    }

    private static func matchDecodedWindowsDrive(
        _ nsText: NSString, pos: Int, end: Int, dec0: DecodedJsonChar
    ) -> Int? {
        guard isASCIILetter(dec0.ch) && pos + dec0.len < end else { return nil }
        let p1 = pos + dec0.len
        let dec1 = decodeJsonCharAt(nsText, pos: p1, end: end)
        guard dec1.ch == 0x3A && p1 + dec1.len < end else { return nil }
        let p2 = p1 + dec1.len
        let dec2 = decodeJsonCharAt(nsText, pos: p2, end: end)
        return (dec2.ch == 0x2F || dec2.ch == 0x5C) ? p2 + dec2.len : nil
    }

    private static func matchDecodedHomeOrUnc(
        _ nsText: NSString, pos: Int, end: Int, dec0: DecodedJsonChar
    ) -> Int? {
        guard (dec0.ch == 0x7E || dec0.ch == 0x5C) && pos + dec0.len < end else { return nil }
        let p1 = pos + dec0.len
        let dec1 = decodeJsonCharAt(nsText, pos: p1, end: end)
        return ((dec0.ch == 0x7E && dec1.ch == 0x2F) || (dec0.ch == 0x5C && dec1.ch == 0x5C)) ? p1 + dec1.len : nil
    }

    private static func stepPlainQuotedChar(
        _ nsText: NSString, pos: Int, end: Int, dec0: DecodedJsonChar, tokenStart: inout Int
    ) -> QuotedScanStep {
        if isDecodedWhitespace(dec0.ch) || isQuotedPathDelimiter(dec0.ch) {
            tokenStart = -1
        } else if dec0.ch == 0x5C {
            if tokenStart >= 0 {
                return checkTrailingNonWS(
                    nsText, matchPos: tokenStart, afterPos: pos + dec0.len, end: end, tokenStart: &tokenStart
                )
            }
        } else if tokenStart < 0 {
            tokenStart = pos
        }
        return QuotedScanStep(found: -1, nextPos: pos + dec0.len)
    }

    private static func checkSlashRun(
        _ nsText: NSString, pos: Int, afterPos: Int, end: Int, tokenStart: inout Int
    ) -> QuotedScanStep {
        if tokenStart >= 0 {
            return checkTrailingNonWS(nsText, matchPos: tokenStart, afterPos: afterPos, end: end, tokenStart: &tokenStart)
        }
        let (nextRoot, stopCh) = scanSlashRunEnd(nsText, pos: afterPos, end: end)
        if nextRoot < end && !isDecodedWhitespace(stopCh) {
            return QuotedScanStep(found: pos, nextPos: nextRoot)
        }
        return QuotedScanStep(found: -1, nextPos: nextRoot)
    }

    private static func checkTrailingNonWS(
        _ nsText: NSString, matchPos: Int, afterPos: Int, end: Int, tokenStart: inout Int
    ) -> QuotedScanStep {
        let (next, stopCh) = nextNonHorizontalSpaceDecoded(nsText, pos: afterPos, end: end)
        if next < end && !isDecodedWhitespace(stopCh) {
            return QuotedScanStep(found: matchPos, nextPos: next)
        }
        tokenStart = -1
        return QuotedScanStep(found: -1, nextPos: next)
    }

    private static func scanSlashRunEnd(_ nsText: NSString, pos: Int, end: Int) -> (Int, unichar) {
        var next = pos
        while next < end {
            let dec = decodeJsonCharAt(nsText, pos: next, end: end)
            if dec.ch == 0x2F || isHorizontalSpace(dec.ch) {
                next += dec.len
            } else {
                return (next, dec.ch)
            }
        }
        return (next, 0)
    }

    private static func nextNonHorizontalSpaceDecoded(_ nsText: NSString, pos: Int, end: Int) -> (Int, unichar) {
        var idx = pos
        while idx < end {
            let dec = decodeJsonCharAt(nsText, pos: idx, end: end)
            if isHorizontalSpace(dec.ch) {
                idx += dec.len
            } else {
                return (idx, dec.ch)
            }
        }
        return (idx, 0)
    }

    private static func isDecodedWhitespace(_ ch: unichar) -> Bool {
        VaultLineTracker.isWhitespace(ch) || ch == 0x08
    }

    private static func isHorizontalSpace(_ ch: unichar) -> Bool {
        ch == 0x20 || ch == 0x09
    }

    private static func isQuotedPathDelimiter(_ ch: unichar) -> Bool {
        switch ch {
        case 0x22, 0x27, 0x3C, 0x3E, 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x3A, 0x2C, 0x3B, 0x3D:
            return true
        default:
            return false
        }
    }
}

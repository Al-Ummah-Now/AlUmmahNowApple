import Foundation

extension CoreTelemetryService {
    static func replaceKeywordQuotedPaths(in text: String, regex: NSRegularExpression) -> String {
        let nsText = text as NSString
        guard text.contains("\"") else {
            let range = NSRange(location: 0, length: nsText.length)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1[redacted-path]")
        }
        var spans = collectBalancedDoubleQuoteSpans(nsText)
        if spans.isEmpty {
            let range = NSRange(location: 0, length: nsText.length)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1[redacted-path]")
        }
        let masked = buildMaskedDoubleQuotes(nsText, spans: spans)
        let afterUnquoted = applyMaskedPathRegex(text, masked: masked, regex: regex, hasPrefix: true)
        let nsCur = afterUnquoted as NSString
        if afterUnquoted != text {
            guard afterUnquoted.contains("\"") else { return afterUnquoted }
            spans = collectBalancedDoubleQuoteSpans(nsCur)
        }
        return replaceKeywordQuotedInSpans(nsCur, spans: spans, regex: regex)
    }

    private static func replaceKeywordQuotedInSpans(
        _ nsCur: NSString, spans: [QuotedPathSpan], regex: NSRegularExpression
    ) -> String {
        var result = ""
        var copied = 0
        for span in spans {
            let innerStart = span.open + 1
            guard innerStart < span.close && containsQuoteOrQuoteEscape(nsCur, start: innerStart, end: span.close) else {
                continue
            }
            let (decoded, rawOffsets) = decodeQuotedSpanWithOffsets(nsCur, start: innerStart, end: span.close)
            guard decoded.contains("'") || decoded.contains("\"") else { continue }
            let matches = regex.matches(
                in: decoded, options: [], range: NSRange(location: 0, length: (decoded as NSString).length))
            for match in matches {
                let g1 = match.range(at: 1)
                let rawPrefixEnd = rawOffsets[g1.location + g1.length]
                let rawEnd = rawOffsets[match.range.location + match.range.length]
                if result.isEmpty { result.reserveCapacity(nsCur.length) }
                result += nsCur.substring(with: NSRange(location: copied, length: rawPrefixEnd - copied))
                result += "[redacted-path]"
                copied = rawEnd
            }
        }
        guard copied > 0 else { return nsCur as String }
        result += nsCur.substring(from: copied)
        return result
    }

    static func replaceBareFilenames(in text: String, regex: NSRegularExpression) -> String {
        let nsText = text as NSString
        guard text.contains("\"") else {
            let range = NSRange(location: 0, length: nsText.length)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1$2[redacted-path]")
        }
        var spans = collectBalancedDoubleQuoteSpans(nsText)
        if spans.isEmpty {
            let range = NSRange(location: 0, length: nsText.length)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1$2[redacted-path]")
        }
        let masked = buildMaskedDoubleQuotes(nsText, spans: spans)
        let afterUnquoted = applyMaskedBareFilenameRegex(text, masked: masked, regex: regex)
        let nsCur = afterUnquoted as NSString
        if afterUnquoted != text {
            guard afterUnquoted.contains("\"") else { return afterUnquoted }
            spans = collectBalancedDoubleQuoteSpans(nsCur)
        }
        return replaceBareFilenamesInSpans(nsCur, spans: spans, regex: regex)
    }

    private static func applyMaskedBareFilenameRegex(
        _ text: String, masked: String, regex: NSRegularExpression
    ) -> String {
        let nsText = text as NSString
        let matches = regex.matches(in: masked, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var copied = 0
        for match in matches {
            let g2 = match.range(at: 2)
            let prefixEnd = g2.location + g2.length
            let end = match.range.location + match.range.length
            result += nsText.substring(with: NSRange(location: copied, length: prefixEnd - copied))
            result += "[redacted-path]"
            copied = end
        }
        result += nsText.substring(from: copied)
        return result
    }

    private static func replaceBareFilenamesInSpans(
        _ nsCur: NSString, spans: [QuotedPathSpan], regex: NSRegularExpression
    ) -> String {
        var result = ""
        var copied = 0
        for span in spans {
            let innerStart = span.open + 1
            guard innerStart < span.close && containsDotOrUnicodeEscape(nsCur, start: innerStart, end: span.close) else {
                continue
            }
            let (decoded, rawOffsets) = decodeQuotedSpanWithOffsets(nsCur, start: innerStart, end: span.close)
            guard decoded.contains(".") else { continue }
            let nsDec = decoded as NSString
            let followedByAt =
                span.close + 1 < nsCur.length && VaultLineTracker.emailAtLength(nsCur, at: span.close + 1, len: nsCur.length) > 0
            if !hasDecodedPathOrQuoteSep(nsDec) && !followedByAt && endsWithFilenameExt(nsDec, start: 0, end: nsDec.length) {
                if result.isEmpty { result.reserveCapacity(nsCur.length) }
                result += nsCur.substring(with: NSRange(location: copied, length: innerStart - copied))
                result += "[redacted-path]"
                copied = span.close
                continue
            }
            applyBareMatchesInDecoded(
                nsCur, decoded: decoded, rawOffsets: rawOffsets, regex: regex, result: &result, copied: &copied)
        }
        guard copied > 0 else { return nsCur as String }
        result += nsCur.substring(from: copied)
        return result
    }

    // swiftlint:disable:next function_parameter_count
    private static func applyBareMatchesInDecoded(
        _ nsCur: NSString, decoded: String, rawOffsets: [Int],
        regex: NSRegularExpression, result: inout String, copied: inout Int
    ) {
        let matches = regex.matches(in: decoded, options: [], range: NSRange(location: 0, length: (decoded as NSString).length))
        for match in matches {
            let g2 = match.range(at: 2)
            let rawPrefixEnd = rawOffsets[g2.location + g2.length]
            let rawEnd = rawOffsets[match.range.location + match.range.length]
            if result.isEmpty { result.reserveCapacity(nsCur.length) }
            result += nsCur.substring(with: NSRange(location: copied, length: rawPrefixEnd - copied))
            result += "[redacted-path]"
            copied = rawEnd
        }
    }

    static func redactDoubleQuotedFilenamesRespectingQuotes(in text: String) -> String {
        let nsText = text as NSString
        var spans = collectBalancedDoubleQuoteSpans(nsText)
        if spans.isEmpty { return redactDoubleQuotedOnSource(nsText, scanSource: nsText) }
        let masked = buildMaskedDoubleQuotes(nsText, spans: spans)
        let afterUnquoted = redactDoubleQuotedOnSource(nsText, scanSource: masked as NSString)
        let nsCur = afterUnquoted as NSString
        if afterUnquoted != text {
            guard afterUnquoted.contains("\"") else { return afterUnquoted }
            spans = collectBalancedDoubleQuoteSpans(nsCur)
        }
        return redactDoubleQuotedInSpans(nsCur, spans: spans)
    }

    private static func redactDoubleQuotedOnSource(_ nsText: NSString, scanSource: NSString) -> String {
        guard (scanSource as String).contains(".") else { return nsText as String }
        let len = scanSource.length
        var result = ""
        var copied = 0
        var idx = 0
        while idx < len {
            guard scanSource.character(at: idx) == 0x22 else { idx += 1; continue }
            var close = idx + 1
            while close < len {
                let ch = scanSource.character(at: close)
                if ch == 0x22 || isQuotedSegStop(ch) { break }
                close += 1
            }
            let followedByAt = close + 1 < len && VaultLineTracker.emailAtLength(scanSource, at: close + 1, len: len) > 0
            if close < len && scanSource.character(at: close) == 0x22 && !followedByAt
                && endsWithFilenameExt(scanSource, start: idx + 1, end: close)
            {
                if result.isEmpty { result.reserveCapacity(nsText.length) }
                result += nsText.substring(with: NSRange(location: copied, length: idx - copied))
                result += "\"[redacted-path]\""
                copied = close + 1
                idx = close + 1
            } else {
                idx = (close < len && scanSource.character(at: close) == 0x22) ? close : close + 1
            }
        }
        guard copied > 0 else { return nsText as String }
        result += nsText.substring(from: copied)
        return result
    }

    private static func redactDoubleQuotedInSpans(_ nsCur: NSString, spans: [QuotedPathSpan]) -> String {
        var result = ""
        var copied = 0
        for span in spans {
            let innerStart = span.open + 1
            guard innerStart < span.close && containsDotOrUnicodeEscape(nsCur, start: innerStart, end: span.close) else {
                continue
            }
            let (decoded, rawOffsets) = decodeQuotedSpanWithOffsets(nsCur, start: innerStart, end: span.close)
            guard decoded.contains(".") else { continue }
            let nsDec = decoded as NSString
            let followedByAt =
                span.close + 1 < nsCur.length && VaultLineTracker.emailAtLength(nsCur, at: span.close + 1, len: nsCur.length) > 0
            if !hasDecodedSegStop(nsDec) && !followedByAt && endsWithFilenameExt(nsDec, start: 0, end: nsDec.length) {
                if result.isEmpty { result.reserveCapacity(nsCur.length) }
                result += nsCur.substring(with: NSRange(location: copied, length: innerStart - copied))
                result += "[redacted-path]"
                copied = span.close
            } else if decoded.contains("\"") {
                applyDoubleQuotedSpans(nsCur, decoded: nsDec, rawOffsets: rawOffsets, result: &result, copied: &copied)
            }
        }
        guard copied > 0 else { return nsCur as String }
        result += nsCur.substring(from: copied)
        return result
    }

    private static func applyDoubleQuotedSpans(
        _ nsCur: NSString, decoded: NSString, rawOffsets: [Int], result: inout String, copied: inout Int
    ) {
        let len = decoded.length
        var idx = 0
        while idx < len {
            guard decoded.character(at: idx) == 0x22 else { idx += 1; continue }
            var close = idx + 1
            while close < len {
                let ch = decoded.character(at: close)
                if ch == 0x22 || isQuotedSegStop(ch) { break }
                close += 1
            }
            let followedByAt = close + 1 < len && VaultLineTracker.emailAtLength(decoded, at: close + 1, len: len) > 0
            if close < len && decoded.character(at: close) == 0x22 && !followedByAt
                && endsWithFilenameExt(decoded, start: idx + 1, end: close)
            {
                let rawInnerStart = rawOffsets[idx + 1]
                let rawInnerEnd = rawOffsets[close]
                if result.isEmpty { result.reserveCapacity(nsCur.length) }
                result += nsCur.substring(with: NSRange(location: copied, length: rawInnerStart - copied))
                result += "[redacted-path]"
                copied = rawInnerEnd
                idx = close + 1
            } else {
                idx = (close < len && decoded.character(at: close) == 0x22) ? close : close + 1
            }
        }
    }

    static func redactSingleQuotedFilenamesRespectingQuotes(in text: String) -> String {
        let nsText = text as NSString
        guard text.contains("\"") else { return redactSingleQuotedFilenamesOnSource(nsText, scanSource: nsText) }
        var spans = collectBalancedDoubleQuoteSpans(nsText)
        if spans.isEmpty { return redactSingleQuotedFilenamesOnSource(nsText, scanSource: nsText) }
        let masked = buildMaskedDoubleQuotes(nsText, spans: spans)
        let afterUnquoted = redactSingleQuotedFilenamesOnSource(nsText, scanSource: masked as NSString)
        let nsCur = afterUnquoted as NSString
        if afterUnquoted != text {
            guard afterUnquoted.contains("\"") else { return afterUnquoted }
            spans = collectBalancedDoubleQuoteSpans(nsCur)
        }
        var result = ""
        var copied = 0
        for span in spans {
            let innerStart = span.open + 1
            guard
                innerStart < span.close && containsSingleQuoteOrUnicodeEscape(nsCur, start: innerStart, end: span.close)
                    && containsDotOrUnicodeEscape(nsCur, start: innerStart, end: span.close)
            else { continue }
            let (decoded, rawOffsets) = decodeQuotedSpanWithOffsets(nsCur, start: innerStart, end: span.close)
            guard decoded.contains("'") && decoded.contains(".") else { continue }
            applySingleQuotedSpans(nsCur, decoded: decoded as NSString, rawOffsets: rawOffsets, result: &result, copied: &copied)
        }
        guard copied > 0 else { return afterUnquoted }
        result += nsCur.substring(from: copied)
        return result
    }

    static func redactKeywordUnquotedFilenamesRespectingQuotes(
        in text: String, kwRegex: NSRegularExpression
    ) -> String {
        let nsText = text as NSString
        guard text.contains("\"") else { return redactKeywordUnquotedOnSource(nsText, scanSource: nsText, kwRegex: kwRegex) }
        var spans = collectBalancedDoubleQuoteSpans(nsText)
        if spans.isEmpty { return redactKeywordUnquotedOnSource(nsText, scanSource: nsText, kwRegex: kwRegex) }
        let masked = buildMaskedDoubleQuotes(nsText, spans: spans)
        let afterUnquoted = redactKeywordUnquotedOnSource(nsText, scanSource: masked as NSString, kwRegex: kwRegex)
        let nsCur = afterUnquoted as NSString
        if afterUnquoted != text {
            guard afterUnquoted.contains("\"") else { return afterUnquoted }
            spans = collectBalancedDoubleQuoteSpans(nsCur)
        }
        var result = ""
        var copied = 0
        for span in spans {
            let innerStart = span.open + 1
            guard innerStart < span.close && containsDotOrUnicodeEscape(nsCur, start: innerStart, end: span.close) else {
                continue
            }
            let (decoded, rawOffsets) = decodeQuotedSpanWithOffsets(nsCur, start: innerStart, end: span.close)
            guard decoded.contains(".") else { continue }
            applyKeywordUnquotedSpans(
                nsCur, decoded: decoded, rawOffsets: rawOffsets, kwRegex: kwRegex, result: &result, copied: &copied
            )
        }
        guard copied > 0 else { return afterUnquoted }
        result += nsCur.substring(from: copied)
        return result
    }

    // swiftlint:disable:next function_parameter_count
    private static func applyKeywordUnquotedSpans(
        _ nsCur: NSString, decoded: String, rawOffsets: [Int],
        kwRegex: NSRegularExpression, result: inout String, copied: inout Int
    ) {
        let nsDec = decoded as NSString
        let len = nsDec.length
        let hasAt = VaultLineTracker.hasEmailAt(decoded)
        var decCopied = 0
        var segStart = 0
        while segStart < len {
            var segEnd = segStart
            while segEnd < len {
                let ch = nsDec.character(at: segEnd)
                if ch == 0x0A || ch == 0x0D || ch == 0x1E || ch == 0x1F { break }
                segEnd += 1
            }
            if let (lastDot, lastExtEnd) = findLastUnquotedFilenameExt(nsDec, segStart: segStart, segEnd: segEnd, len: len),
                let kwMatch = kwRegex.firstMatch(
                    in: decoded, options: [], range: NSRange(location: segStart, length: lastDot - segStart))
            {
                let kwEnd = kwMatch.range.location + kwMatch.range.length
                let emailEnd = hasAt ? VaultLineTracker.findEmailTailEnd(nsDec, from: lastExtEnd, len: len) : -1
                if emailEnd > 0 && !VaultLineTracker.containsWhitespace(nsDec, from: kwEnd, to: lastDot) {
                    segStart = segEnd + 1
                    continue
                }
                let endPos = max(lastExtEnd, emailEnd)
                if result.isEmpty { result.reserveCapacity(nsCur.length) }
                result += nsCur.substring(with: NSRange(location: copied, length: rawOffsets[kwEnd] - copied))
                result += "[redacted-path]"
                copied = rawOffsets[endPos]
                decCopied = endPos
            }
            segStart = max(segEnd + 1, decCopied)
        }
    }

    private static func hasDecodedSegStop(_ nsDec: NSString) -> Bool {
        let len = nsDec.length
        var idx = 0
        while idx < len {
            if isQuotedSegStop(nsDec.character(at: idx)) { return true }
            idx += 1
        }
        return false
    }

    private static func hasDecodedPathOrQuoteSep(_ nsDec: NSString) -> Bool {
        let len = nsDec.length
        var idx = 0
        while idx < len {
            let ch = nsDec.character(at: idx)
            if ch == 0x22 || isQuotedSegStop(ch) { return true }
            idx += 1
        }
        return false
    }

    static func containsDotOrUnicodeEscape(_ nsText: NSString, start: Int, end: Int) -> Bool {
        var idx = start
        while idx < end {
            let ch = nsText.character(at: idx)
            if ch == 0x2E { return true }
            if ch == 0x5C && idx + 1 < end {
                if nsText.character(at: idx + 1) == 0x75 && idx + 5 < end { return true }
                idx += 2
                continue
            }
            idx += 1
        }
        return false
    }

    private static func containsQuoteOrQuoteEscape(_ nsText: NSString, start: Int, end: Int) -> Bool {
        var idx = start
        while idx < end {
            let ch = nsText.character(at: idx)
            if ch == 0x27 { return true }
            if ch == 0x5C && idx + 1 < end {
                let next = nsText.character(at: idx + 1)
                if next == 0x22 || (next == 0x75 && idx + 5 < end) { return true }
                idx += 2
                continue
            }
            idx += 1
        }
        return false
    }

    private static func containsSingleQuoteOrUnicodeEscape(_ nsText: NSString, start: Int, end: Int) -> Bool {
        var idx = start
        while idx < end {
            let ch = nsText.character(at: idx)
            if ch == 0x27 { return true }
            if ch == 0x5C && idx + 1 < end {
                if nsText.character(at: idx + 1) == 0x75 && idx + 5 < end { return true }
                idx += 2
                continue
            }
            idx += 1
        }
        return false
    }
}

import Foundation

enum CoreTelemetryQuotedPathHelpers {
    static func scanVaultIndexEnd(_ nsText: NSString, from numStart: Int, limit: Int) -> Int {
        var pos = numStart
        let maxEnd = min(limit, numStart + 10)
        while pos < maxEnd {
            let ch = nsText.character(at: pos)
            if ch < 0x30 || ch > 0x39 { break }
            pos += 1
        }
        return pos > numStart && pos < limit && nsText.character(at: pos) == 0x1F ? pos : -1
    }

    static func resolveFileURIQuoteBounds(
        _ nsText: NSString,
        pos: Int,
        spans: [CoreTelemetryService.QuotedPathSpan]?,
        spanIdx: inout Int
    ) -> (isDoubleQuoted: Bool, limit: Int) {
        if let spans {
            while spanIdx < spans.count && spans[spanIdx].close <= pos { spanIdx += 1 }
            if spanIdx < spans.count && spans[spanIdx].open < pos && pos < spans[spanIdx].close {
                let innerClose = findInnerEscapedQuoteClose(
                    nsText, pathPos: pos, minPos: spans[spanIdx].open + 1, segEnd: spans[spanIdx].close
                )
                return (true, innerClose >= 0 ? innerClose : nsText.length)
            }
        }
        return (pos > 0 && nsText.character(at: pos - 1) == 0x22, nsText.length)
    }

    static func findInnerEscapedQuoteClose(
        _ nsText: NSString,
        pathPos: Int,
        minPos: Int,
        segEnd: Int
    ) -> Int {
        guard isPrecededByEscapedQuote(nsText, at: pathPos, minPos: minPos) else { return -1 }
        return findClosingEscapedQuote(nsText, start: pathPos, end: segEnd)
    }

    static func isOddBackslashesBefore(_ nsText: NSString, at pos: Int, minPos: Int) -> Bool {
        var bs = 0
        while pos - 1 - bs >= minPos && nsText.character(at: pos - 1 - bs) == 0x5C { bs += 1 }
        return (bs & 1) == 1
    }

    private static func isPrecededByEscapedQuote(_ nsText: NSString, at pos: Int, minPos: Int) -> Bool {
        if pos >= minPos + 2 && nsText.character(at: pos - 1) == 0x22
            && nsText.character(at: pos - 2) == 0x5C
            && !isOddBackslashesBefore(nsText, at: pos - 2, minPos: minPos)
        {
            return true
        }
        return pos >= minPos + 6 && isEscapedQuoteAt(nsText, at: pos - 6, end: pos)
            && !isOddBackslashesBefore(nsText, at: pos - 6, minPos: minPos)
    }

    private static func isEscapedQuoteAt(_ nsText: NSString, at pos: Int, end: Int) -> Bool {
        if pos + 2 <= end && nsText.character(at: pos) == 0x5C && nsText.character(at: pos + 1) == 0x22 {
            return true
        }
        guard pos + 6 <= end && nsText.character(at: pos) == 0x5C && nsText.character(at: pos + 1) == 0x75 else {
            return false
        }
        return nsText.character(at: pos + 2) == 0x30 && nsText.character(at: pos + 3) == 0x30
            && nsText.character(at: pos + 4) == 0x32 && nsText.character(at: pos + 5) == 0x32
    }

    private static func isUnicodeBackslashAt(_ nsText: NSString, at pos: Int, end: Int) -> Bool {
        guard pos + 6 <= end && nsText.character(at: pos) == 0x5C && nsText.character(at: pos + 1) == 0x75 else {
            return false
        }
        let d3 = nsText.character(at: pos + 5)
        return nsText.character(at: pos + 2) == 0x30 && nsText.character(at: pos + 3) == 0x30
            && nsText.character(at: pos + 4) == 0x35 && (d3 == 0x63 || d3 == 0x43)
    }

    private static func findClosingEscapedQuote(_ nsText: NSString, start: Int, end: Int) -> Int {
        var pos = start
        var innerEscaped = false
        while pos < end {
            if nsText.character(at: pos) == 0x5C && pos + 1 < end {
                if !innerEscaped && isEscapedQuoteAt(nsText, at: pos, end: end) { return pos }
                let next = nsText.character(at: pos + 1)
                if next == 0x5C {
                    innerEscaped.toggle()
                    pos += 2
                } else if next == 0x75 && pos + 5 < end {
                    innerEscaped = isUnicodeBackslashAt(nsText, at: pos, end: end) ? !innerEscaped : false
                    pos += 6
                } else {
                    innerEscaped = false
                    pos += 2
                }
                continue
            }
            innerEscaped = false
            pos += 1
        }
        return -1
    }
}

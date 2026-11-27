import Foundation

extension CoreTelemetryService {
    static func isContainerValueStart(_ nsText: NSString, quotePos: Int) -> Bool {
        var idx = quotePos - 1
        while idx >= 0 && isHorizontalSpace(nsText.character(at: idx)) { idx -= 1 }
        guard idx >= 0 else { return false }
        let ch = nsText.character(at: idx)
        return ch == 0x5B || ch == 0x7B || ch == 0x2C || ch == 0x3A
    }

    static func isOuterQuoteCloser(
        _ nsText: NSString, at pos: Int, outerQuote: unichar, isContainerValue: Bool
    ) -> Bool {
        let len = nsText.length
        var idx = pos + 1
        if idx >= len || isLineBreak(nsText.character(at: idx)) { return true }
        guard isContainerValue else { return false }
        while idx < len && isContainerCloserOrSpace(nsText.character(at: idx)) { idx += 1 }
        if idx >= len || isLineBreak(nsText.character(at: idx)) { return true }
        return nsText.character(at: idx) == 0x2C
            && hasContainerSiblingAfterComma(nsText, commaPos: idx, outerQuote: outerQuote)
    }

    private static func hasContainerSiblingAfterComma(
        _ nsText: NSString, commaPos: Int, outerQuote: unichar
    ) -> Bool {
        let len = nsText.length
        var idx = skipHorizontalSpaces(nsText, from: commaPos + 1, len: len)
        while idx < len {
            let ch = nsText.character(at: idx)
            if ch == outerQuote || isContainerSiblingDelimiter(ch) { return true }
            let next = scanContainerScalar(nsText, from: idx, len: len)
            guard next > idx else { return false }
            idx = skipHorizontalSpaces(nsText, from: next, len: len)
            if idx >= len || isContainerEndOrBreak(nsText.character(at: idx)) { return true }
            guard nsText.character(at: idx) == 0x2C else { return false }
            idx = skipHorizontalSpaces(nsText, from: idx + 1, len: len)
        }
        return true
    }

    private static func scanContainerScalar(_ nsText: NSString, from pos: Int, len: Int) -> Int {
        var end = scanContainerNumber(nsText, from: pos, len: len)
        if end < 0 { end = matchContainerKeyword(nsText, from: pos, len: len) }
        guard end > pos else { return -1 }
        if end >= len || isScalarBoundary(nsText.character(at: end)) { return end }
        return -1
    }

    private static func scanContainerNumber(_ nsText: NSString, from pos: Int, len: Int) -> Int {
        let start = nsText.character(at: pos) == 0x2D ? pos + 1 : pos
        var idx = scanDigits(nsText, from: start, len: len)
        guard idx > 0 else { return -1 }
        if idx < len && nsText.character(at: idx) == 0x2E {
            idx = scanDigits(nsText, from: idx + 1, len: len)
            guard idx > 0 else { return -1 }
        }
        if idx < len && (nsText.character(at: idx) == 0x65 || nsText.character(at: idx) == 0x45) {
            var expStart = idx + 1
            if expStart < len && (nsText.character(at: expStart) == 0x2B || nsText.character(at: expStart) == 0x2D) {
                expStart += 1
            }
            idx = scanDigits(nsText, from: expStart, len: len)
        }
        return idx
    }

    private static func scanDigits(_ nsText: NSString, from start: Int, len: Int) -> Int {
        var idx = start
        while idx < len && isASCIIDigit(nsText.character(at: idx)) { idx += 1 }
        return idx > start ? idx : -1
    }

    private static func matchContainerKeyword(_ nsText: NSString, from pos: Int, len: Int) -> Int {
        let keywords = ["true", "null", "True", "None", "false", "False"]
        for keyword in keywords where pos + keyword.count <= len {
            let range = NSRange(location: pos, length: keyword.count)
            if nsText.substring(with: range) == keyword { return pos + keyword.count }
        }
        return -1
    }

    private static func skipHorizontalSpaces(_ nsText: NSString, from start: Int, len: Int) -> Int {
        var idx = start
        while idx < len && isHorizontalSpace(nsText.character(at: idx)) { idx += 1 }
        return idx
    }

    private static func isHorizontalSpace(_ ch: unichar) -> Bool { ch == 0x20 || ch == 0x09 }
    private static func isLineBreak(_ ch: unichar) -> Bool { ch == 0x0D || ch == 0x0A }
    private static func isContainerCloserOrSpace(_ ch: unichar) -> Bool {
        ch == 0x7D || ch == 0x5D || isHorizontalSpace(ch)
    }
    private static func isContainerEndOrBreak(_ ch: unichar) -> Bool {
        ch == 0x5D || ch == 0x7D || isLineBreak(ch)
    }
    private static func isContainerSiblingDelimiter(_ ch: unichar) -> Bool {
        ch == 0x7B || ch == 0x5B || isContainerEndOrBreak(ch)
    }
    private static func isScalarBoundary(_ ch: unichar) -> Bool {
        ch == 0x2C || isHorizontalSpace(ch) || isContainerEndOrBreak(ch)
    }
}

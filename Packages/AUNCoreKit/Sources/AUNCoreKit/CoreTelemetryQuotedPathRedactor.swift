import Foundation

extension CoreTelemetryService {
    private struct QuotedPathSpan {
        let close: Int
        let lastVaultEnd: Int
        let stopPos: Int
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
            let span = findDoubleQuotedPathEnd(nsText, start: idx + 1, len: len)
            if span.close < 0 {
                idx = span.stopPos + 1
                continue
            }
            let sliceStart = span.lastVaultEnd > idx + 1 ? span.lastVaultEnd : idx + 1
            let pathPos = sliceStart < span.close ? findLocalPathStartInQuoted(nsText, start: sliceStart, end: span.close) : -1
            if pathPos >= 0 {
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copied, length: pathPos - copied))
                result += "[redacted-path]"
                copied = span.close
            }
            idx = span.close + 1
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func isOddBackslashesBefore(_ nsText: NSString, at pos: Int, minPos: Int) -> Bool {
        var bs = 0
        while pos - 1 - bs >= minPos && nsText.character(at: pos - 1 - bs) == 0x5C { bs += 1 }
        return (bs & 1) == 1
    }

    private static func findDoubleQuotedPathEnd(_ nsText: NSString, start: Int, len: Int) -> QuotedPathSpan {
        var lastVaultEnd = -1
        var escaped = false
        var pos = start
        while pos < len {
            let ch = nsText.character(at: pos)
            if ch == 0x0D || ch == 0x0A {
                return QuotedPathSpan(close: -1, lastVaultEnd: lastVaultEnd, stopPos: pos)
            }
            if ch == 0x1F {
                lastVaultEnd = pos + 1
                escaped = false
            } else if ch == 0x22 && !escaped {
                return QuotedPathSpan(close: pos, lastVaultEnd: lastVaultEnd, stopPos: pos)
            } else {
                escaped = ch == 0x5C && !escaped
            }
            pos += 1
        }
        return QuotedPathSpan(close: -1, lastVaultEnd: lastVaultEnd, stopPos: len)
    }

    private static func findLocalPathStartInQuoted(_ nsText: NSString, start: Int, end: Int) -> Int {
        var tokenStart = -1
        var pos = start
        while pos < end {
            let ch = nsText.character(at: pos)
            if ch == 0x5C && pos + 1 < end && nsText.character(at: pos + 1) == 0x22 {
                tokenStart = -1
                pos += 2
                continue
            }
            if isWindowsDriveAt(nsText, at: pos, len: end) && hasNonWhitespaceAfter(nsText, pos: pos + 3, end: end) {
                return pos
            }
            if tokenStart < 0 && isQuotedLocalPathStart(nsText, at: pos, end: end) { return pos }
            if let found = stepQuotedPathToken(nsText, pos: pos, end: end, ch: ch, tokenStart: &tokenStart) {
                return found
            }
            pos += 1
        }
        return -1
    }

    private static func stepQuotedPathToken(
        _ nsText: NSString, pos: Int, end: Int, ch: unichar, tokenStart: inout Int
    ) -> Int? {
        if VaultLineTracker.isWhitespace(ch) || isQuotedPathDelimiter(ch) {
            tokenStart = -1
        } else if ch == 0x2F || ch == 0x5C {
            if tokenStart >= 0 && hasNonWhitespaceAfter(nsText, pos: pos + 1, end: end) { return tokenStart }
            tokenStart = -1
        } else if tokenStart < 0 {
            tokenStart = pos
        }
        return nil
    }

    private static func isQuotedLocalPathStart(_ nsText: NSString, at pos: Int, end: Int) -> Bool {
        let ch = nsText.character(at: pos)
        if ch == 0x2F {
            var next = pos + 1
            while next < end && nsText.character(at: next) == 0x2F { next += 1 }
            while next < end && isHorizontalSpace(nsText.character(at: next)) { next += 1 }
            return next < end && !VaultLineTracker.isWhitespace(nsText.character(at: next))
                && nsText.character(at: next) != 0x2F
        }
        if ch == 0x7E && pos + 1 < end && nsText.character(at: pos + 1) == 0x2F {
            return hasNonWhitespaceAfter(nsText, pos: pos + 2, end: end)
        }
        if ch == 0x5C && pos + 1 < end && nsText.character(at: pos + 1) == 0x5C {
            return hasNonWhitespaceAfter(nsText, pos: pos + 2, end: end)
        }
        return false
    }

    private static func hasNonWhitespaceAfter(_ nsText: NSString, pos: Int, end: Int) -> Bool {
        var idx = pos
        while idx < end && isHorizontalSpace(nsText.character(at: idx)) { idx += 1 }
        return idx < end && !VaultLineTracker.isWhitespace(nsText.character(at: idx))
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

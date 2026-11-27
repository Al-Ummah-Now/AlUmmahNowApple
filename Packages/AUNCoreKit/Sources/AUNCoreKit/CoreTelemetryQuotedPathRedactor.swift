import Foundation

extension CoreTelemetryService {
    private struct QuotedPathSpan {
        let close: Int
        let lastVaultEnd: Int
        let stopPos: Int
    }

    private struct QuotedScanStep {
        let found: Int
        let nextPos: Int
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
            var pathPos = sliceStart < span.close ? findLocalPathStartInQuoted(nsText, start: sliceStart, end: span.close) : -1
            if pathPos >= 0 {
                if pathPos > sliceStart && isOddBackslashesBefore(nsText, at: pathPos, minPos: sliceStart) {
                    pathPos -= 1
                }
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
            let step = stepQuotedPathScanner(nsText, pos: pos, end: end, tokenStart: &tokenStart)
            if step.found >= 0 { return step.found }
            pos = step.nextPos
        }
        return -1
    }

    private static func stepQuotedPathScanner(
        _ nsText: NSString, pos: Int, end: Int, tokenStart: inout Int
    ) -> QuotedScanStep {
        let ch = nsText.character(at: pos)
        if ch == 0x5C && pos + 1 < end && nsText.character(at: pos + 1) == 0x22 {
            tokenStart = -1
            return QuotedScanStep(found: -1, nextPos: pos + 2)
        }
        if isWindowsDriveAt(nsText, at: pos, len: end) {
            return checkTrailingNonWS(nsText, matchPos: pos, afterPos: pos + 3, end: end, tokenStart: &tokenStart)
        }
        if ch == 0x2F || (ch == 0x5C && pos + 1 < end && nsText.character(at: pos + 1) == 0x2F) {
            let step = ch == 0x5C ? 2 : 1
            return checkSlashRun(nsText, pos: pos, afterPos: pos + step, end: end, tokenStart: &tokenStart)
        }
        if tokenStart < 0 && isQuotedHomeOrUncPrefix(nsText, at: pos, end: end, ch: ch) {
            return checkTrailingNonWS(nsText, matchPos: pos, afterPos: pos + 2, end: end, tokenStart: &tokenStart)
        }
        return stepPlainQuotedChar(nsText, pos: pos, end: end, ch: ch, tokenStart: &tokenStart)
    }

    private static func stepPlainQuotedChar(
        _ nsText: NSString, pos: Int, end: Int, ch: unichar, tokenStart: inout Int
    ) -> QuotedScanStep {
        if VaultLineTracker.isWhitespace(ch) || isQuotedPathDelimiter(ch) {
            tokenStart = -1
        } else if ch == 0x5C {
            if tokenStart >= 0 {
                return checkTrailingNonWS(
                    nsText, matchPos: tokenStart, afterPos: pos + 1, end: end, tokenStart: &tokenStart
                )
            }
        } else if tokenStart < 0 {
            tokenStart = pos
        }
        return QuotedScanStep(found: -1, nextPos: pos + 1)
    }

    private static func checkSlashRun(
        _ nsText: NSString, pos: Int, afterPos: Int, end: Int, tokenStart: inout Int
    ) -> QuotedScanStep {
        if tokenStart >= 0 {
            return checkTrailingNonWS(nsText, matchPos: tokenStart, afterPos: afterPos, end: end, tokenStart: &tokenStart)
        }
        let nextRoot = scanSlashRunEnd(nsText, pos: afterPos, end: end)
        if nextRoot < end && !VaultLineTracker.isWhitespace(nsText.character(at: nextRoot)) {
            return QuotedScanStep(found: pos, nextPos: nextRoot)
        }
        return QuotedScanStep(found: -1, nextPos: nextRoot)
    }

    private static func checkTrailingNonWS(
        _ nsText: NSString, matchPos: Int, afterPos: Int, end: Int, tokenStart: inout Int
    ) -> QuotedScanStep {
        let next = nextNonHorizontalSpace(nsText, pos: afterPos, end: end)
        if next < end && !VaultLineTracker.isWhitespace(nsText.character(at: next)) {
            return QuotedScanStep(found: matchPos, nextPos: next)
        }
        tokenStart = -1
        return QuotedScanStep(found: -1, nextPos: next)
    }

    private static func isQuotedHomeOrUncPrefix(_ nsText: NSString, at pos: Int, end: Int, ch: unichar) -> Bool {
        guard pos + 1 < end else { return false }
        let nextCh = nsText.character(at: pos + 1)
        return (ch == 0x7E && nextCh == 0x2F) || (ch == 0x5C && nextCh == 0x5C)
    }

    private static func scanSlashRunEnd(_ nsText: NSString, pos: Int, end: Int) -> Int {
        var next = pos
        while next < end {
            let ch = nsText.character(at: next)
            if ch == 0x2F || isHorizontalSpace(ch) {
                next += 1
            } else if ch == 0x5C && next + 1 < end && nsText.character(at: next + 1) == 0x2F {
                next += 2
            } else {
                break
            }
        }
        return next
    }

    private static func nextNonHorizontalSpace(_ nsText: NSString, pos: Int, end: Int) -> Int {
        var idx = pos
        while idx < end && isHorizontalSpace(nsText.character(at: idx)) { idx += 1 }
        return idx
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

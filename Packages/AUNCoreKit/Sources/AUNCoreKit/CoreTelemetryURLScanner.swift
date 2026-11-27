import Foundation

extension CoreTelemetryService {
    struct URLScanMatch {
        let start: Int
        let baseEnd: Int
        let totalEnd: Int
        let hasQueryOrFragment: Bool
    }

    static func findNonFileSchemeStart(_ nsText: NSString, sep: Int, minStart: Int) -> Int? {
        var start = sep
        while start > minStart && VaultLineTracker.isURLSchemeChar(nsText.character(at: start - 1)) {
            start -= 1
        }
        guard sep - start >= 2, isASCIILetter(nsText.character(at: start)) else { return nil }
        if start > 0 {
            let prev = nsText.character(at: start - 1)
            if VaultLineTracker.isURLSchemeChar(prev) || prev == 0x2F || prev == 0x5C { return nil }
        }
        if sep - start == 4
            && nsText.substring(with: NSRange(location: start, length: 4)).lowercased() == "file"
        {
            return nil
        }
        return start
    }

    static func scanURLAfterScheme(_ nsText: NSString, start: Int, sep: Int) -> URLScanMatch? {
        let totalLen = nsText.length
        guard let afterHost = scanURLHost(nsText, hostStart: sep + 3, len: totalLen),
            let afterPort = scanOptionalPort(nsText, pos: afterHost, len: totalLen)
        else { return nil }
        let (baseEnd, truncated): (Int, Bool) =
            if afterPort < totalLen && nsText.character(at: afterPort) == 0x2F {
                scanURLPath(nsText, start: afterPort, len: totalLen)
            } else {
                (afterPort, false)
            }
        var totalEnd = baseEnd
        var hasQF = false
        if !truncated && baseEnd < totalLen {
            let nextCh = nsText.character(at: baseEnd)
            if nextCh == 0x3F || nextCh == 0x23 {
                hasQF = true
                totalEnd = scanQueryOrFragment(nsText, start: baseEnd, len: totalLen)
            }
        }
        guard totalEnd == totalLen || isURLEndBoundary(nsText, at: totalEnd, len: totalLen) else { return nil }
        return URLScanMatch(start: start, baseEnd: baseEnd, totalEnd: totalEnd, hasQueryOrFragment: hasQF)
    }

    private static func scanURLHost(_ nsText: NSString, hostStart: Int, len: Int) -> Int? {
        guard hostStart < len else { return nil }
        if nsText.character(at: hostStart) == 0x5B {
            return scanIPv6Host(nsText, hostStart: hostStart, len: len)
        }
        var pos = hostStart
        while pos < len {
            let ch = nsText.character(at: pos)
            if isURLHostChar(ch) {
                pos += 1
            } else if ch == 0x25 && pos + 2 < len
                && isHexDigit(nsText.character(at: pos + 1)) && isHexDigit(nsText.character(at: pos + 2))
            {
                pos += 3
            } else {
                break
            }
        }
        return pos > hostStart ? pos : nil
    }

    private static func scanIPv6Host(_ nsText: NSString, hostStart: Int, len: Int) -> Int? {
        var close = hostStart + 1
        while close < len {
            let ch = nsText.character(at: close)
            if ch == 0x5D { break }
            if VaultLineTracker.isWhitespace(ch) || isForbiddenIPv6Char(ch) { return nil }
            close += 1
        }
        guard close < len, nsText.character(at: close) == 0x5D, close > hostStart + 1 else { return nil }
        let host = nsText.substring(with: NSRange(location: hostStart + 1, length: close - hostStart - 1))
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) == 1 }) else { return nil }
        return close + 1
    }

    private static func scanOptionalPort(_ nsText: NSString, pos: Int, len: Int) -> Int? {
        guard pos < len && nsText.character(at: pos) == 0x3A else { return pos }
        var idx = pos + 1
        while idx < len && isASCIIDigit(nsText.character(at: idx)) { idx += 1 }
        return idx > pos + 1 ? idx : nil
    }

    private static func scanURLPath(_ nsText: NSString, start: Int, len: Int) -> (Int, Bool) {
        var openPositions: [Int] = []
        var openChars: [unichar] = []
        var pos = start
        while pos < len {
            let next = stepURLPathChar(nsText, pos: pos, len: len, openPositions: &openPositions, openChars: &openChars)
            if next < 0 { break }
            pos = next
        }
        if let firstUnclosed = openPositions.first { return (firstUnclosed, true) }
        return (pos, false)
    }

    private static func stepURLPathChar(
        _ nsText: NSString, pos: Int, len: Int, openPositions: inout [Int], openChars: inout [unichar]
    ) -> Int {
        if VaultLineTracker.isFileScheme(nsText, at: pos) || isWindowsDriveAt(nsText, at: pos, len: len) { return -1 }
        let ch = nsText.character(at: pos)
        if VaultLineTracker.isWhitespace(ch) || isURLPathStopChar(ch) { return -1 }
        if ch == 0x28 || ch == 0x5B {
            if startsEmbeddedPathInsideGroup(nsText, nextPos: pos + 1, len: len) { return -1 }
            openPositions.append(pos)
            openChars.append(ch)
            return pos + 1
        }
        if ch == 0x29 || ch == 0x5D {
            let expected: unichar = ch == 0x29 ? 0x28 : 0x5B
            guard openChars.last == expected else { return -1 }
            openPositions.removeLast()
            openChars.removeLast()
            return pos + 1
        }
        return (!openChars.isEmpty && ch == 0x3A) ? -1 : pos + 1
    }

    private static func startsEmbeddedPathInsideGroup(_ nsText: NSString, nextPos: Int, len: Int) -> Bool {
        guard nextPos < len else { return true }
        let ch = nsText.character(at: nextPos)
        if ch == 0x2F || ch == 0x5C || ch == 0x3A { return true }
        if ch == 0x7E && nextPos + 1 < len && nsText.character(at: nextPos + 1) == 0x2F { return true }
        return VaultLineTracker.isFileScheme(nsText, at: nextPos) || isWindowsDriveAt(nsText, at: nextPos, len: len)
    }

    private static func scanQueryOrFragment(_ nsText: NSString, start: Int, len: Int) -> Int {
        var pos = start + 1
        while pos < len {
            let ch = nsText.character(at: pos)
            if VaultLineTracker.isWhitespace(ch) || ch == 0x22 || ch == 0x3C || ch == 0x3E { break }
            pos += 1
        }
        return pos
    }

    private static func isURLEndBoundary(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        let ch = nsText.character(at: pos)
        if VaultLineTracker.isWhitespace(ch) || isURLEndBoundaryChar(ch) { return true }
        return VaultLineTracker.isFileScheme(nsText, at: pos) || isWindowsDriveAt(nsText, at: pos, len: len)
    }

    private static func isWindowsDriveAt(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        pos + 2 < len && isASCIILetter(nsText.character(at: pos))
            && nsText.character(at: pos + 1) == 0x3A
            && VaultLineTracker.isPathSep(nsText.character(at: pos + 2))
    }

    static func isASCIILetter(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)
    }

    static func isASCIIDigit(_ ch: unichar) -> Bool { ch >= 0x30 && ch <= 0x39 }

    private static func isHexDigit(_ ch: unichar) -> Bool {
        isASCIIDigit(ch) || (ch >= 0x41 && ch <= 0x46) || (ch >= 0x61 && ch <= 0x66)
    }

    private static func isURLHostChar(_ ch: unichar) -> Bool {
        isASCIILetter(ch) || isASCIIDigit(ch)
            || ch == 0x2E || ch == 0x5F || ch == 0x7E || ch == 0x21 || ch == 0x24 || ch == 0x26
            || ch == 0x27 || ch == 0x2A || ch == 0x2B || ch == 0x3B || ch == 0x3D || ch == 0x2D
    }

    private static func isForbiddenIPv6Char(_ ch: unichar) -> Bool {
        ch == 0x5B || ch == 0x22 || ch == 0x27 || ch == 0x3C || ch == 0x3E
            || ch == 0x5C || ch == 0x7B || ch == 0x7D || ch == 0x0A || ch == 0x0D
    }

    private static func isURLPathStopChar(_ ch: unichar) -> Bool {
        ch == 0x22 || ch == 0x3C || ch == 0x3E || ch == 0x5C || ch == 0x7B || ch == 0x7D
            || ch == 0x2C || ch == 0x3F || ch == 0x23 || ch == 0x0A || ch == 0x0D
    }

    private static func isURLEndBoundaryChar(_ ch: unichar) -> Bool {
        ch == 0x22 || ch == 0x27 || ch == 0x3C || ch == 0x3E || ch == 0x5C || ch == 0x7B || ch == 0x7D
            || ch == 0x2C || ch == 0x3B || ch == 0x28 || ch == 0x29 || ch == 0x5B || ch == 0x5D
    }
}

extension CoreTelemetryService.VaultLineTracker {
    static func emailAtLength(_ nsText: NSString, at pos: Int, len: Int) -> Int {
        let ch = nsText.character(at: pos)
        if ch == 0x40 { return 1 }  // '@'
        if ch == 0x25 && pos + 2 < len
            && nsText.character(at: pos + 1) == 0x34 && nsText.character(at: pos + 2) == 0x30
        {
            return 3  // "%40"
        }
        return 0
    }

    static func findEmailLocalStart(_ nsText: NSString, at atPos: Int, minPos: Int, len: Int) -> Int {
        if atPos > minPos && nsText.character(at: atPos - 1) == 0x22
            && !isPrecededByOddBackslashes(nsText, at: atPos - 1, minPos: minPos)
        {
            return findQuotedEmailLocalStart(nsText, at: atPos, minPos: minPos)
        }
        var localStart = atPos
        while localStart > minPos && isEmailLocalChar(nsText, at: localStart - 1, len: len) {
            localStart -= 1
        }
        var trimmedStart = localStart
        while trimmedStart < atPos && isEmailLeadingWrapper(nsText.character(at: trimmedStart)) {
            trimmedStart += 1
        }
        return trimmedStart < atPos ? trimmedStart : localStart
    }

    private static func findQuotedEmailLocalStart(_ nsText: NSString, at atPos: Int, minPos: Int) -> Int {
        var idx = atPos - 2
        while idx >= minPos {
            let ch = nsText.character(at: idx)
            if ch == 0x0A || ch == 0x0D { return atPos }
            if ch == 0x22 && !isPrecededByOddBackslashes(nsText, at: idx, minPos: minPos) { return idx }
            idx -= 1
        }
        return atPos
    }

    private static func isPrecededByOddBackslashes(_ nsText: NSString, at pos: Int, minPos: Int) -> Bool {
        var count = 0
        var idx = pos - 1
        while idx >= minPos && nsText.character(at: idx) == 0x5C {
            count += 1
            idx -= 1
        }
        return (count & 1) == 1
    }

    static func findIPLiteralDomainEnd(_ nsText: NSString, domStart: Int, len: Int) -> Int {
        var close = domStart + 1
        while close < len {
            let ch = nsText.character(at: close)
            if ch == 0x5D { break }
            if isWhitespace(ch) || ch == 0x5B || ch == 0x22 || ch == 0x27 || ch == 0x3C || ch == 0x3E
                || ch == 0x5C || ch == 0x7B || ch == 0x7D || ch == 0x0A || ch == 0x0D
            {
                return -1
            }
            close += 1
        }
        guard close < len, nsText.character(at: close) == 0x5D, close > domStart + 1 else { return -1 }
        let inner = nsText.substring(with: NSRange(location: domStart + 1, length: close - domStart - 1))
        if inner.lowercased().hasPrefix("ipv6:") {
            let v6 = String(inner.dropFirst(5))
            var addr = in6_addr()
            return v6.withCString({ inet_pton(AF_INET6, $0, &addr) == 1 }) ? close + 1 : -1
        }
        var addr4 = in_addr()
        return inner.withCString({ inet_pton(AF_INET, $0, &addr4) == 1 }) ? close + 1 : -1
    }

    static func isEmailLocalChar(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        let ch = nsText.character(at: pos)
        if CoreTelemetryService.isASCIILetter(ch) || CoreTelemetryService.isASCIIDigit(ch)
            || isEmailLocalPunct(ch) || isNonASCIIEmailLocalChar(ch)
        {
            return true
        }
        return ch == 0x25
            && !(pos + 2 < len && nsText.character(at: pos + 1) == 0x34 && nsText.character(at: pos + 2) == 0x30)
    }

    static func isEmailLeadingWrapper(_ ch: unichar) -> Bool {
        if ch == 0x27 || ch == 0x7B || ch == 0x7D { return true }
        guard ch >= 0x80, !isSurrogate(ch), let scalar = UnicodeScalar(ch) else { return false }
        let cat = scalar.properties.generalCategory
        return cat == .openPunctuation || cat == .initialPunctuation
    }

    private static func isEmailLocalPunct(_ ch: unichar) -> Bool {
        switch ch {
        case 0x2E, 0x5F, 0x2B, 0x2D, 0x21, 0x23, 0x24, 0x26, 0x27, 0x2A, 0x5E, 0x60, 0x7B, 0x7C, 0x7D, 0x7E:
            return true
        default:
            return false
        }
    }

    private static func isNonASCIIEmailLocalChar(_ ch: unichar) -> Bool {
        guard ch >= 0x80 else { return false }
        if isSurrogate(ch) { return true }
        guard let scalar = UnicodeScalar(ch) else { return false }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
            && !CharacterSet.controlCharacters.contains(scalar)
    }

    static func isPunycodeTLD(_ nsText: NSString, start: Int, end: Int, allASCII: Bool) -> Bool {
        guard allASCII && end - start >= 6 else { return false }
        let last = nsText.character(at: end - 1)
        guard CoreTelemetryService.isASCIILetter(last) || CoreTelemetryService.isASCIIDigit(last) else {
            return false
        }
        return matchesASCIIUpper3(nsText, at: start, c0: 0x58, c1: 0x4E, c2: 0x2D)
            && nsText.character(at: start + 3) == 0x2D
    }

    static func isUnicodeCombiningMark(_ ch: unichar) -> Bool {
        ch >= 0x80 && (UnicodeScalar(ch).map { CharacterSet.nonBaseCharacters.contains($0) } ?? false)
    }

    static func isSurrogate(_ ch: unichar) -> Bool { ch >= 0xD800 && ch <= 0xDFFF }

    static func isLowSurrogate(_ ch: unichar) -> Bool { ch >= 0xDC00 && ch <= 0xDFFF }

    static func isEmailDigit(_ ch: unichar) -> Bool {
        if ch < 0x80 { return ch >= 0x30 && ch <= 0x39 }
        return UnicodeScalar(ch).map { CharacterSet.decimalDigits.contains($0) } ?? false
    }

    static func isEmailLetter(_ ch: unichar) -> Bool {
        isLetter(ch) || isUnicodeCombiningMark(ch) || isSurrogate(ch)
    }

    static func isEmailBoundaryBlocked(_ ch: unichar) -> Bool {
        isLetterOrDigit(ch) || ch == 0x5F || isUnicodeCombiningMark(ch)
    }
}

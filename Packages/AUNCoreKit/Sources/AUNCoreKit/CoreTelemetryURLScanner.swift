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

    static func scanURLPath(_ nsText: NSString, start: Int, len: Int) -> (Int, Bool) {
        var openGroups: [(pos: Int, ch: unichar)] = []
        var openBraces = 0
        var pos = start
        while pos < len {
            let next = stepURLPathChar(nsText, pos: pos, len: len, openGroups: &openGroups, openBraces: &openBraces)
            if next < 0 { break }
            pos = next
        }
        if let firstUnclosed = openGroups.first?.pos { return (firstUnclosed, true) }
        return (pos, false)
    }

    private static func stepURLPathChar(
        _ nsText: NSString, pos: Int, len: Int, openGroups: inout [(pos: Int, ch: unichar)], openBraces: inout Int
    ) -> Int {
        if isURLPathTerminator(nsText, pos: pos, len: len) { return -1 }
        let ch = nsText.character(at: pos)
        if isURLGroupOpener(ch) {
            if openBraces > 0 || startsEmbeddedPathInsideGroup(nsText, nextPos: pos + 1, len: len) { return -1 }
            openGroups.append((pos, ch))
            if ch == 0x7B { openBraces += 1 }
            return pos + 1
        }
        if isURLGroupCloser(ch) {
            return popURLPathGroup(ch, openGroups: &openGroups, openBraces: &openBraces) ? pos + 1 : -1
        }
        if openBraces > 0 && !isURLBraceTemplateChar(ch) { return -1 }
        if !openGroups.isEmpty && (ch == 0x3A || (ch == 0x27 && (pos == 0 || !isASCIIAlphaNum(nsText.character(at: pos - 1))))) {
            return -1
        }
        return pos + 1
    }

    private static func isURLBraceTemplateChar(_ ch: unichar) -> Bool {
        isASCIIAlphaNum(ch) || ch == 0x5F || ch == 0x2D
    }

    private static func isURLGroupOpener(_ ch: unichar) -> Bool {
        ch == 0x28 || ch == 0x5B || ch == 0x7B
    }

    private static func isURLGroupCloser(_ ch: unichar) -> Bool {
        ch == 0x29 || ch == 0x5D || ch == 0x7D
    }

    private static func isURLPathTerminator(_ nsText: NSString, pos: Int, len: Int) -> Bool {
        if VaultLineTracker.isFileScheme(nsText, at: pos) || isWindowsDriveAt(nsText, at: pos, len: len) { return true }
        let ch = nsText.character(at: pos)
        return ch == 0x2C || VaultLineTracker.isWhitespace(ch) || isURLPathStopChar(ch)
    }

    private static func popURLPathGroup(
        _ ch: unichar, openGroups: inout [(pos: Int, ch: unichar)], openBraces: inout Int
    ) -> Bool {
        let expected: unichar = ch == 0x29 ? 0x28 : (ch == 0x5D ? 0x5B : 0x7B)
        guard openGroups.last?.ch == expected else { return false }
        openGroups.removeLast()
        if ch == 0x7D { openBraces -= 1 }
        return true
    }

    static func startsEmbeddedFilesystemPath(_ nsText: NSString, nextPos: Int, len: Int) -> Bool {
        guard nextPos < len else { return true }
        let ch = nsText.character(at: nextPos)
        if ch == 0x2F || ch == 0x5C { return true }
        if ch == 0x7E && nextPos + 1 < len && nsText.character(at: nextPos + 1) == 0x2F { return true }
        return VaultLineTracker.isFileScheme(nsText, at: nextPos) || isWindowsDriveAt(nsText, at: nextPos, len: len)
    }

    static func startsEmbeddedPathInsideGroup(_ nsText: NSString, nextPos: Int, len: Int) -> Bool {
        guard nextPos < len else { return true }
        if nsText.character(at: nextPos) == 0x3A { return true }
        return startsEmbeddedFilesystemPath(nsText, nextPos: nextPos, len: len)
    }

    static func scanQueryOrFragment(_ nsText: NSString, start: Int, len: Int) -> Int {
        var pos = start + 1
        while pos < len {
            let ch = nsText.character(at: pos)
            if VaultLineTracker.isWhitespace(ch) || ch == 0x3C || ch == 0x3E { break }
            if ch == 0x22 {
                var bs = 0
                while pos - 1 - bs > start && nsText.character(at: pos - 1 - bs) == 0x5C { bs += 1 }
                if (bs & 1) == 0 { break }
            }
            pos += 1
        }
        return pos
    }

    static func advanceQuoteState(
        _ nsText: NSString, from start: Int, to end: Int, quoteState: Int
    ) -> Int {
        var inSingle = (quoteState & 1) != 0
        var inDouble = (quoteState & 2) != 0
        var idx = start
        let len = nsText.length
        while idx < end {
            let ch = nsText.character(at: idx)
            if ch == 0x0D || ch == 0x0A {
                inSingle = false
                inDouble = false
            } else if ch == 0x5C && (inSingle || inDouble) && idx + 1 < end {
                let next = nsText.character(at: idx + 1)
                if next != 0x0D && next != 0x0A {
                    idx += 2
                    continue
                }
            } else if ch == 0x22 && !inSingle {
                inDouble.toggle()
            } else if ch == 0x27 && !inDouble && !isContractionApostrophe(nsText, at: idx, len: len) {
                inSingle.toggle()
            }
            idx += 1
        }
        return (inSingle ? 1 : 0) | (inDouble ? 2 : 0)
    }

    static func isContractionApostrophe(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        pos > 0 && pos + 1 < len
            && Self.isASCIIAlphaNum(nsText.character(at: pos - 1))
            && Self.isASCIIAlphaNum(nsText.character(at: pos + 1))
    }

    private static func isURLEndBoundary(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        let ch = nsText.character(at: pos)
        if VaultLineTracker.isWhitespace(ch) || isURLEndBoundaryChar(ch) { return true }
        return VaultLineTracker.isFileScheme(nsText, at: pos) || isWindowsDriveAt(nsText, at: pos, len: len)
    }

    static func isWindowsDriveAt(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
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

    static func isURLPathStopChar(_ ch: unichar) -> Bool {
        ch == 0x22 || ch == 0x3C || ch == 0x3E || ch == 0x5C || ch == 0x3F || ch == 0x23 || ch == 0x0A || ch == 0x0D
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
        while localStart > minPos && isEmailLocalChar(nsText, at: localStart - 1, len: len)
            && !isSchemeSlash(nsText, at: localStart - 1)
        {
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

    static func findNextEmailClosingQuote(_ nsText: NSString, from start: Int, len: Int) -> (Int, Int) {
        var idx = start
        var escaped = false
        while idx < len {
            let ch = nsText.character(at: idx)
            if ch == 0x0D || ch == 0x0A {
                let afterNewline = (ch == 0x0D && idx + 1 < len && nsText.character(at: idx + 1) == 0x0A) ? idx + 2 : idx + 1
                if afterNewline < len {
                    let next = nsText.character(at: afterNewline)
                    if next == 0x20 || next == 0x09 {
                        escaped = false
                        idx = afterNewline + 1
                        continue
                    }
                }
                return (-1, idx)
            }
            if ch == 0x22 && !escaped { return (idx, idx) }
            escaped = ch == 0x5C && !escaped
            idx += 1
        }
        return (-1, len)
    }

    static func isPrecededByOddBackslashes(_ nsText: NSString, at pos: Int, minPos: Int) -> Bool {
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

    private static func isSchemeSlash(_ nsText: NSString, at pos: Int) -> Bool {
        pos >= 2 && nsText.character(at: pos) == 0x2F
            && nsText.character(at: pos - 1) == 0x2F && nsText.character(at: pos - 2) == 0x3A
    }

    private static func isEmailLocalPunct(_ ch: unichar) -> Bool {
        switch ch {
        case 0x2E, 0x5F, 0x2B, 0x2D, 0x2F, 0x21, 0x23, 0x24, 0x26, 0x27, 0x2A, 0x3D, 0x3F, 0x5E, 0x60, 0x7B, 0x7C, 0x7D, 0x7E:
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

    enum DomainCharKind {
        case other
        case letter
        case digit
        case dot
        case hyphen
    }

    static func isSurrogate(_ ch: unichar) -> Bool { ch >= 0xD800 && ch <= 0xDFFF }

    static func isEmailDomainDot(_ ch: unichar) -> Bool {
        ch == 0x2E || ch == 0x3002 || ch == 0xFF0E || ch == 0xFF61
    }

    private static func decodeScalar(_ nsText: NSString, at pos: Int, len: Int) -> (UnicodeScalar, Int)? {
        let ch = nsText.character(at: pos)
        if ch >= 0xD800 && ch <= 0xDBFF {
            guard pos + 1 < len else { return nil }
            let low = nsText.character(at: pos + 1)
            guard low >= 0xDC00 && low <= 0xDFFF else { return nil }
            let codePoint = 0x10000 + ((Int(ch) - 0xD800) << 10) + (Int(low) - 0xDC00)
            return UnicodeScalar(codePoint).map { ($0, 2) }
        }
        guard ch < 0xDC00 || ch > 0xDFFF else { return nil }
        return UnicodeScalar(ch).map { ($0, 1) }
    }

    private static func classifyDomainChar(_ nsText: NSString, at pos: Int, len: Int) -> (DomainCharKind, Int) {
        let ch = nsText.character(at: pos)
        if ch < 0x80 {
            if CoreTelemetryService.isASCIILetter(ch) { return (.letter, 1) }
            if CoreTelemetryService.isASCIIDigit(ch) { return (.digit, 1) }
            if ch == 0x2E { return (.dot, 1) }
            return (ch == 0x2D ? .hyphen : .other, 1)
        }
        if isEmailDomainDot(ch) { return (.dot, 1) }
        guard let (scalar, step) = decodeScalar(nsText, at: pos, len: len) else { return (.other, 1) }
        if CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
            return (.letter, step)
        }
        return (CharacterSet.decimalDigits.contains(scalar) ? .digit : .other, step)
    }

    static func hasEmailAt(_ text: String) -> Bool {
        text.contains("@") || text.contains("%40")
    }

    static func containsWhitespace(_ nsText: NSString, from start: Int, to end: Int) -> Bool {
        var idx = start
        while idx < end {
            if isWhitespace(nsText.character(at: idx)) { return true }
            idx += 1
        }
        return false
    }

    static func findEmailTailEnd(_ nsText: NSString, from pos: Int, len: Int) -> Int {
        var idx = pos
        while idx < len && isEmailLocalChar(nsText, at: idx, len: len) { idx += 1 }
        guard idx < len else { return -1 }
        let atLen = emailAtLength(nsText, at: idx, len: len)
        return atLen > 0 ? findEmailDomainEnd(nsText, domStart: idx + atLen, len: len) : -1
    }

    static func redactQuotedEmails(in text: String) -> String {
        guard text.contains("\"") && hasEmailAt(text) else { return text }
        let nsText = text as NSString
        let len = nsText.length
        var result = ""
        var copied = 0
        var idx = 0
        var cacheUntil = -1
        var cachedClose = -1
        while idx < len {
            if nsText.character(at: idx) == 0x22 && !isPrecededByOddBackslashes(nsText, at: idx, minPos: copied),
                let qEnd = matchQuotedEmailEnd(nsText, at: idx, cacheUntil: &cacheUntil, cachedClose: &cachedClose)
            {
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copied, length: idx - copied))
                result += "[redacted-email]"
                copied = qEnd
                idx = qEnd
                cacheUntil = -1
            } else {
                idx += 1
            }
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    static func matchQuotedEmailEnd(
        _ nsText: NSString, at pos: Int, cacheUntil: inout Int, cachedClose: inout Int
    ) -> Int? {
        let len = nsText.length
        let closeQuote: Int
        if pos < cacheUntil {
            closeQuote = cachedClose
        } else {
            let (found, stopPos) = findNextEmailClosingQuote(nsText, from: pos + 1, len: len)
            cachedClose = found
            cacheUntil = found >= 0 ? found : stopPos
            closeQuote = found
        }
        guard closeQuote > pos, closeQuote + 1 < len else { return nil }
        let atPos = closeQuote + 1
        let atLen = emailAtLength(nsText, at: atPos, len: len)
        guard atLen > 0 else { return nil }
        let domEnd = findEmailDomainEnd(nsText, domStart: atPos + atLen, len: len)
        return domEnd > 0 ? domEnd : nil
    }

    static func findEmailDomainEnd(_ nsText: NSString, domStart: Int, len: Int) -> Int {
        if domStart < len && nsText.character(at: domStart) == 0x5B {
            return findIPLiteralDomainEnd(nsText, domStart: domStart, len: len)
        }
        var idx = domStart
        var labelStart = domStart
        var labelHasLetter = false
        var bestEnd = -1
        while idx < len {
            let (kind, step) = classifyDomainChar(nsText, at: idx, len: len)
            if kind == .letter {
                labelHasLetter = true
            } else if kind == .dot {
                if idx == labelStart || nsText.character(at: idx - 1) == 0x2D { break }
                labelStart = idx + 1
                labelHasLetter = false
            } else if kind == .hyphen {
                if idx == labelStart { break }
            } else if kind != .digit {
                break
            }
            idx += step
            if isValidDomainLabelEnd(nsText, labelStart: labelStart, end: idx, labelHasLetter: labelHasLetter) {
                bestEnd = idx
            }
        }
        return bestEnd
    }

    static func isEmailBoundaryBlocked(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        let (kind, _) = classifyDomainChar(nsText, at: pos, len: len)
        return kind == .letter || kind == .digit || kind == .hyphen || nsText.character(at: pos) == 0x5F
    }

    private static func isValidDomainLabelEnd(
        _ nsText: NSString, labelStart: Int, end: Int, labelHasLetter: Bool
    ) -> Bool {
        let len = nsText.length
        guard end > labelStart, labelHasLetter, nsText.character(at: end - 1) != 0x2D else { return false }
        guard end == len || !isEmailBoundaryBlocked(nsText, at: end, len: len) else { return false }
        if end + 1 < len && isEmailDomainDot(nsText.character(at: end)) {
            let (nextKind, _) = classifyDomainChar(nsText, at: end + 1, len: len)
            if nextKind == .letter || nextKind == .digit { return false }
        }
        return true
    }
}

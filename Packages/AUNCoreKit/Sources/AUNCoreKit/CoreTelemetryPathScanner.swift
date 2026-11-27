import Foundation

extension CoreTelemetryService {
    static func escapeSentinels(_ text: String) -> (String, Bool) {
        let needsEscape = text.utf16.contains { $0 == 0x18 || $0 == 0x1E || $0 == 0x1F }
        guard needsEscape else { return (text, false) }
        var out: [unichar] = []
        out.reserveCapacity(text.utf16.count + 8)
        for unit in text.utf16 {
            switch unit {
            case 0x18: out.append(contentsOf: [0x18, 0x18])
            case 0x1E: out.append(contentsOf: [0x18, 0x19])
            case 0x1F: out.append(contentsOf: [0x18, 0x1A])
            default: out.append(unit)
            }
        }
        return (String(utf16CodeUnits: out, count: out.count), true)
    }

    static func unescapeSentinels(_ text: String) -> String {
        let units = Array(text.utf16)
        guard units.contains(0x18) else { return text }
        var out: [unichar] = []
        out.reserveCapacity(units.count)
        var idx = 0
        while idx < units.count {
            if units[idx] == 0x18 && idx + 1 < units.count {
                switch units[idx + 1] {
                case 0x18: out.append(0x18); idx += 2; continue
                case 0x19: out.append(0x1E); idx += 2; continue
                case 0x1A: out.append(0x1F); idx += 2; continue
                default: break
                }
            }
            out.append(units[idx])
            idx += 1
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    struct VaultLineTracker {
        private var cursor = 0
        private var hasPathOnLine = false
        private var openQuote: unichar = 0
        private var pathQuote: unichar = 0
        private var escapedBackslash = false
        private var tokenStart = -1
        private var tokenEnd = -1
        private var tokenHasPathSep = false
        private var inWrapperRun = false
        private var wsBeforeRun = false

        mutating func isEmbeddedInPath(_ nsText: NSString, matchStart: Int) -> Bool {
            advance(nsText, to: matchStart)
            let curTokenIsPath =
                tokenHasPathSep
                && !Self.isNonPathSlashToken(nsText, start: tokenStart, end: tokenEnd, insideQuote: openQuote != 0)
            return pathQuote != 0 || curTokenIsPath || (hasPathOnLine && (!wsBeforeRun || inWrapperRun))
        }

        mutating func onVaultedURL(matchEnd: Int) {
            cursor = matchEnd
            resetLineState()
        }

        private mutating func resetLineState() {
            hasPathOnLine = false
            openQuote = 0
            pathQuote = 0
            escapedBackslash = false
            tokenStart = -1
            tokenEnd = -1
            tokenHasPathSep = false
            inWrapperRun = false
            wsBeforeRun = false
        }

        private mutating func advance(_ nsText: NSString, to target: Int) {
            while cursor < target {
                let ch = nsText.character(at: cursor)
                if ch == 0x0A || ch == 0x0D {
                    resetLineState()
                } else {
                    processLineChar(nsText, ch: ch)
                }
                cursor += 1
            }
        }

        private mutating func processLineChar(_ nsText: NSString, ch: unichar) {
            if handleClosingQuote(nsText, ch: ch) { return }
            let atTokenStart = tokenStart < 0 || inWrapperRun
            if Self.isFileScheme(nsText, at: cursor) || Self.startsLocalPath(nsText, at: cursor, atTokenStart: atTokenStart) {
                hasPathOnLine = true
                if pathQuote == 0 && openQuote != 0 { pathQuote = openQuote }
            }
            updateRunState(nsText, ch: ch)
            escapedBackslash = (ch == 0x5C) ? !escapedBackslash : false
        }

        private mutating func handleClosingQuote(_ nsText: NSString, ch: unichar) -> Bool {
            guard !escapedBackslash && openQuote != 0 && ch == openQuote else { return false }
            if Self.isInnerApostrophe(nsText, at: cursor, ch: ch) { return false }
            if pathQuote == ch || !hasPathOnLine {
                resetLineState()
            } else {
                openQuote = 0
                tokenStart = -1
                tokenEnd = -1
                tokenHasPathSep = false
                inWrapperRun = false
                wsBeforeRun = false
                escapedBackslash = false
            }
            return true
        }

        private mutating func promoteTokenPath(_ nsText: NSString) {
            if tokenHasPathSep
                && !Self.isNonPathSlashToken(nsText, start: tokenStart, end: tokenEnd, insideQuote: openQuote != 0)
            {
                hasPathOnLine = true
                if pathQuote == 0 && openQuote != 0 { pathQuote = openQuote }
            }
        }

        private mutating func updateRunState(_ nsText: NSString, ch: unichar) {
            if Self.isWhitespace(ch) {
                if !inWrapperRun {
                    promoteTokenPath(nsText)
                    tokenStart = -1
                    tokenEnd = -1
                    wsBeforeRun = true
                    tokenHasPathSep = false
                }
            } else if Self.isOpeningWrapper(ch) {
                if !inWrapperRun { promoteTokenPath(nsText) }
                if !escapedBackslash && openQuote == 0 && Self.canOpenQuote(nsText, at: cursor, ch: ch) {
                    openQuote = ch
                }
                inWrapperRun = true
            } else {
                if tokenStart < 0 || inWrapperRun {
                    tokenStart = cursor
                    tokenHasPathSep = false
                }
                tokenEnd = cursor + 1
                if Self.isPathSep(ch) { tokenHasPathSep = true }
                inWrapperRun = false
                wsBeforeRun = false
            }
        }

        private static func canOpenQuote(_ nsText: NSString, at pos: Int, ch: unichar) -> Bool {
            if ch == 0x22 { return true }
            guard ch == 0x27 else { return false }
            return pos == 0 || !isLetterOrDigit(nsText.character(at: pos - 1))
        }

        static func isInnerApostrophe(_ nsText: NSString, at pos: Int, ch: unichar) -> Bool {
            ch == 0x27 && pos > 0 && pos + 1 < nsText.length
                && isLetterOrDigit(nsText.character(at: pos - 1)) && isLetter(nsText.character(at: pos + 1))
        }

        private static func isLetter(_ ch: unichar) -> Bool {
            if ch < 0x80 { return (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) }
            return UnicodeScalar(ch).map { CharacterSet.letters.contains($0) } ?? false
        }

        static func isLetterOrDigit(_ ch: unichar) -> Bool {
            if ch < 0x80 {
                return (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x30 && ch <= 0x39)
            }
            return UnicodeScalar(ch).map { CharacterSet.alphanumerics.contains($0) } ?? false
        }

        private static func startsLocalPath(_ nsText: NSString, at pos: Int, atTokenStart: Bool) -> Bool {
            guard atTokenStart else { return false }
            let ch = nsText.character(at: pos)
            if ch == 0x2F { return true }
            if ch == 0x7E && pos + 1 < nsText.length && nsText.character(at: pos + 1) == 0x2F { return true }
            if ch == 0x5C && pos + 1 < nsText.length && nsText.character(at: pos + 1) == 0x5C { return true }
            let isAsciiLetter = (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)
            return isAsciiLetter && pos + 2 < nsText.length && nsText.character(at: pos + 1) == 0x3A
                && isPathSep(nsText.character(at: pos + 2))
        }

        private static func isNonPathSlashToken(
            _ nsText: NSString, start: Int, end: Int, insideQuote: Bool
        ) -> Bool {
            guard !insideQuote && start >= 0 && end > start else { return false }
            var trimmedEnd = end
            while trimmedEnd > start && isTrailingSentencePunct(nsText.character(at: trimmedEnd - 1)) {
                trimmedEnd -= 1
            }
            guard trimmedEnd > start else { return false }
            let token = nsText.substring(with: NSRange(location: start, length: trimmedEnd - start))
            guard !token.contains("\\"), let slashIdx = token.firstIndex(of: "/") else { return false }
            let before = token[..<slashIdx]
            let after = token[token.index(after: slashIdx)...]
            guard !before.isEmpty, !after.isEmpty, !after.contains("/") else { return false }
            let upper = before.uppercased()
            let isProto = upper == "HTTP" || upper == "TLS" || upper == "SSL"
            if isProto, let firstDigit = after.first, firstDigit.isASCII && firstDigit.isNumber {
                return true
            }
            return before.allSatisfy { $0.isASCII && $0.isNumber } && after.allSatisfy { $0.isASCII && $0.isNumber }
        }

        private static func isTrailingSentencePunct(_ ch: unichar) -> Bool {
            ch == 0x2E || ch == 0x2C || ch == 0x3B || ch == 0x3A || ch == 0x21
                || ch == 0x3F || ch == 0x29 || ch == 0x5D || ch == 0x7D
        }

        static func isFileScheme(_ nsText: NSString, at pos: Int) -> Bool {
            guard pos + 7 <= nsText.length else { return false }
            if pos > 0 && isURLSchemeChar(nsText.character(at: pos - 1)) { return false }
            let target: [unichar] = [0x66, 0x69, 0x6C, 0x65, 0x3A, 0x2F, 0x2F]  // "file://"
            for offset in 0..<7 {
                let raw = nsText.character(at: pos + offset)
                let folded = (raw >= 0x41 && raw <= 0x5A) ? (raw + 0x20) : raw
                if folded != target[offset] { return false }
            }
            return true
        }

        static func isURLSchemeChar(_ ch: unichar) -> Bool {
            (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)
                || (ch >= 0x30 && ch <= 0x39) || ch == 0x2B || ch == 0x2E || ch == 0x2D
        }

        static func isWhitespace(_ ch: unichar) -> Bool {
            if ch < 0x80 {
                return ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0x0B || ch == 0x0C
            }
            return UnicodeScalar(ch).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }

        static func isOpeningWrapper(_ ch: unichar) -> Bool {
            ch == 0x28 || ch == 0x5B || ch == 0x7B || ch == 0x22 || ch == 0x27
        }

        static func isPathSep(_ ch: unichar) -> Bool {
            ch == 0x2F || ch == 0x5C
        }
    }

    private static func matchesPrefix(_ nsText: NSString, at pos: Int, prefix: NSString) -> Bool {
        let len = prefix.length
        guard pos + len <= nsText.length else { return false }
        for offset in 0..<len where nsText.character(at: pos + offset) != prefix.character(at: offset) {
            return false
        }
        return true
    }

    struct URLScanMatch {
        let start: Int
        let baseEnd: Int
        let totalEnd: Int
        let hasQueryOrFragment: Bool
    }

    static func scanNonFileURL(_ nsText: NSString, sep: Int, minStart: Int) -> URLScanMatch? {
        let totalLen = nsText.length
        guard let start = findSchemeStart(nsText, sep: sep, minStart: minStart),
            let afterHost = scanURLHost(nsText, hostStart: sep + 3, len: totalLen),
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

    private static func findSchemeStart(_ nsText: NSString, sep: Int, minStart: Int) -> Int? {
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

    private static func scanURLHost(_ nsText: NSString, hostStart: Int, len: Int) -> Int? {
        guard hostStart < len else { return nil }
        if nsText.character(at: hostStart) == 0x5B {  // '['
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
            if VaultLineTracker.isFileScheme(nsText, at: pos) || isWindowsDriveAt(nsText, at: pos, len: len) { break }
            let ch = nsText.character(at: pos)
            if VaultLineTracker.isWhitespace(ch) || isURLPathStopChar(ch) { break }
            if ch == 0x28 || ch == 0x5B {
                if startsEmbeddedPathInsideGroup(nsText, nextPos: pos + 1, len: len) { break }
                openPositions.append(pos)
                openChars.append(ch)
                pos += 1
                continue
            }
            if ch == 0x29 || ch == 0x5D {
                let expected: unichar = ch == 0x29 ? 0x28 : 0x5B
                guard openChars.last == expected else { break }
                openPositions.removeLast()
                openChars.removeLast()
                pos += 1
                continue
            }
            if !openChars.isEmpty && ch == 0x3A { break }
            pos += 1
        }
        if let firstUnclosed = openPositions.first { return (firstUnclosed, true) }
        return (pos, false)
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

    private static func isASCIILetter(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)
    }

    private static func isASCIIDigit(_ ch: unichar) -> Bool { ch >= 0x30 && ch <= 0x39 }

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

    static func redactQuotedFilenames(in text: String) -> String {
        guard text.contains(".") else { return text }
        let afterDouble = text.contains("\"") ? redactDoubleQuotedFilenames(in: text) : text
        return afterDouble.contains("'") ? redactSingleQuotedFilenames(in: afterDouble) : afterDouble
    }

    private static func redactDoubleQuotedFilenames(in text: String) -> String {
        let nsText = text as NSString
        let len = nsText.length
        var result = ""
        var copied = 0
        var idx = 0
        while idx < len {
            guard nsText.character(at: idx) == 0x22 else {
                idx += 1
                continue
            }
            var close = idx + 1
            while close < len {
                let ch = nsText.character(at: close)
                if ch == 0x22 || isQuotedSegStop(ch) { break }
                close += 1
            }
            if close < len && nsText.character(at: close) == 0x22 && endsWithFilenameExt(nsText, start: idx + 1, end: close) {
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copied, length: idx - copied))
                result += "[redacted-path]"
                copied = close + 1
            }
            idx = (close < len && nsText.character(at: close) == 0x22) ? close + 1 : close
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func redactSingleQuotedFilenames(in text: String) -> String {
        let nsText = text as NSString
        let len = nsText.length
        var result = ""
        var copied = 0
        var segStart = 0
        while segStart < len {
            var segEnd = segStart
            while segEnd < len && !isQuotedSegStop(nsText.character(at: segEnd)) { segEnd += 1 }
            var minOpen = max(segStart, copied)
            if segStart + 1 < segEnd {
                for close in (segStart + 1)..<segEnd {
                    guard nsText.character(at: close) == 0x27 && endsWithFilenameExt(nsText, start: minOpen, end: close)
                    else { continue }
                    var open = close - 1
                    while open >= minOpen {
                        let isOpener =
                            nsText.character(at: open) == 0x27
                            && (open == segStart || !VaultLineTracker.isLetterOrDigit(nsText.character(at: open - 1)))
                        if isOpener { break }
                        open -= 1
                    }
                    if open >= minOpen && endsWithFilenameExt(nsText, start: open + 1, end: close) {
                        if result.isEmpty { result.reserveCapacity(text.count) }
                        result += nsText.substring(with: NSRange(location: copied, length: open - copied))
                        result += "[redacted-path]"
                        copied = close + 1
                        minOpen = copied
                    }
                }
            }
            segStart = segEnd + 1
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func isQuotedSegStop(_ ch: unichar) -> Bool {
        ch == 0x0A || ch == 0x0D || ch == 0x2F || ch == 0x5C || ch == 0x1E || ch == 0x1F
    }

    private static func endsWithFilenameExt(_ nsText: NSString, start: Int, end: Int) -> Bool {
        var extStart = end
        while extStart > start && end - extStart < 17 {
            let ch = nsText.character(at: extStart - 1)
            if !isASCIILetter(ch) && !isASCIIDigit(ch) { break }
            extStart -= 1
        }
        let extLen = end - extStart
        return extLen >= 1 && extLen <= 16 && extStart > start && nsText.character(at: extStart - 1) == 0x2E
    }

    private static func fileURISpanEnd(
        _ nsText: NSString, after schemeEnd: Int, quote: unichar, vaultPrefix: NSString
    ) -> (rawEnd: Int, trimmedEnd: Int) {
        let totalLength = nsText.length
        var rawEnd = schemeEnd
        var stoppedAtVault = false
        var escapedBackslash = false
        var lastQuotePos = -1
        while rawEnd < totalLength {
            let ch = nsText.character(at: rawEnd)
            if ch == 0x0A || ch == 0x0D { break }
            if ch == 0x1E && matchesPrefix(nsText, at: rawEnd, prefix: vaultPrefix) {
                stoppedAtVault = true
                break
            }
            if quote != 0 && ch == quote && !escapedBackslash { lastQuotePos = rawEnd }
            escapedBackslash = (ch == 0x5C) ? !escapedBackslash : false
            rawEnd += 1
        }
        if lastQuotePos >= 0 { return (lastQuotePos, lastQuotePos) }
        guard stoppedAtVault else { return (rawEnd, rawEnd) }
        var trimmedEnd = rawEnd
        while trimmedEnd > schemeEnd {
            let prev = nsText.character(at: trimmedEnd - 1)
            if VaultLineTracker.isOpeningWrapper(prev) || VaultLineTracker.isWhitespace(prev) {
                trimmedEnd -= 1
            } else {
                break
            }
        }
        return (rawEnd, trimmedEnd)
    }

    static func redactFileURIs(in text: String, vaultPrefix: String) -> String {
        let nsText = text as NSString
        let nsPrefix = vaultPrefix as NSString
        let totalLength = nsText.length
        guard totalLength >= 7 else { return text }
        var result = ""
        var copyStart = 0
        var pos = 0
        while pos < totalLength {
            if VaultLineTracker.isFileScheme(nsText, at: pos) {
                let prev = pos > 0 ? nsText.character(at: pos - 1) : 0
                let quote: unichar = (prev == 0x22 || prev == 0x27) ? prev : 0
                let (rawEnd, trimmedEnd) = fileURISpanEnd(nsText, after: pos + 7, quote: quote, vaultPrefix: nsPrefix)
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copyStart, length: pos - copyStart))
                result += "[redacted-path]"
                result += nsText.substring(with: NSRange(location: trimmedEnd, length: rawEnd - trimmedEnd))
                copyStart = rawEnd
                pos = rawEnd
                continue
            }
            pos += 1
        }
        guard copyStart > 0 else { return text }
        result += nsText.substring(from: copyStart)
        return result
    }
}

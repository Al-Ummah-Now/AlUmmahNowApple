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
        private var tokenFirstSlash = -1
        private var tokenSlashCount = 0
        private var tokenHasBackslash = false
        private var tokenAllDigitsBeforeSlash = true
        private var tokenHasDigitAfterSlash = false
        private var tokenAllDigitsAfterSlash = true
        private var tokenSawPunctAfterSlash = false
        private var inWrapperRun = false
        private var wsBeforeRun = false

        mutating func isEmbeddedInPath(_ nsText: NSString, matchStart: Int) -> Bool {
            advance(nsText, to: matchStart)
            if pathQuote != 0 || (hasPathOnLine && (!wsBeforeRun || inWrapperRun)) { return true }
            return isCurrentTokenPath(nsText)
        }

        mutating func onVaultedURL(matchEnd: Int, activeQuote: unichar = 0) {
            cursor = matchEnd
            resetLineState()
            openQuote = activeQuote
        }

        private mutating func resetTokenState() {
            tokenStart = -1
            tokenEnd = -1
            tokenFirstSlash = -1
            tokenSlashCount = 0
            tokenHasBackslash = false
            tokenAllDigitsBeforeSlash = true
            tokenHasDigitAfterSlash = false
            tokenAllDigitsAfterSlash = true
            tokenSawPunctAfterSlash = false
        }

        private mutating func resetLineState() {
            hasPathOnLine = false
            openQuote = 0
            pathQuote = 0
            escapedBackslash = false
            resetTokenState()
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
            promoteTokenPath(nsText)
            if ch == 0x27 && hasPathOnLine {
                // Single-quoted paths may contain unescaped apostrophes; fail closed on this line.
                escapedBackslash = false
                return true
            }
            if pathQuote == ch || !hasPathOnLine {
                resetLineState()
            } else {
                openQuote = 0
                resetTokenState()
                inWrapperRun = false
                wsBeforeRun = false
                escapedBackslash = false
            }
            return true
        }

        private mutating func promoteTokenPath(_ nsText: NSString) {
            if isCurrentTokenPath(nsText) {
                hasPathOnLine = true
                if pathQuote == 0 && openQuote != 0 { pathQuote = openQuote }
            }
        }

        private mutating func updateRunState(_ nsText: NSString, ch: unichar) {
            if Self.isWhitespace(ch) {
                if !inWrapperRun {
                    promoteTokenPath(nsText)
                    resetTokenState()
                    wsBeforeRun = true
                }
            } else if Self.isOpeningWrapper(ch) {
                if !inWrapperRun { promoteTokenPath(nsText) }
                if !escapedBackslash && openQuote == 0 && Self.canOpenQuote(nsText, at: cursor, ch: ch) {
                    openQuote = ch
                }
                inWrapperRun = true
            } else {
                if tokenStart < 0 || inWrapperRun {
                    resetTokenState()
                    tokenStart = cursor
                }
                tokenEnd = cursor + 1
                trackTokenChar(nsText, ch: ch)
                inWrapperRun = false
                wsBeforeRun = false
            }
        }

        private func isNonPathJsonEscape(_ nsText: NSString) -> Bool {
            guard openQuote == 0x22 && !escapedBackslash && cursor + 1 < nsText.length else { return false }
            let next = nsText.character(at: cursor + 1)
            if next == 0x22 || next == 0x6E || next == 0x72 || next == 0x74 || next == 0x62 || next == 0x66 {
                return true
            }
            guard next == 0x75 && cursor + 5 < nsText.length,
                let code = CoreTelemetryService.parseHex4(nsText, pos: cursor + 2)
            else { return false }
            return code != 0x5C && code != 0x2F
        }

        private mutating func trackTokenChar(_ nsText: NSString, ch: unichar) {
            if ch == 0x5C {
                if !isNonPathJsonEscape(nsText) { tokenHasBackslash = true }
            } else if ch == 0x2F {
                if tokenSlashCount == 0 { tokenFirstSlash = cursor }
                tokenSlashCount += 1
            } else if tokenSlashCount == 0 {
                if !CoreTelemetryService.isASCIIDigit(ch) { tokenAllDigitsBeforeSlash = false }
            } else if tokenSlashCount == 1 {
                trackAfterSlashChar(ch)
            }
        }

        private mutating func trackAfterSlashChar(_ ch: unichar) {
            if Self.isTrailingSentencePunct(ch) {
                tokenSawPunctAfterSlash = true
            } else if CoreTelemetryService.isASCIIDigit(ch) {
                if tokenSawPunctAfterSlash {
                    tokenAllDigitsAfterSlash = false
                } else {
                    tokenHasDigitAfterSlash = true
                }
            } else {
                tokenAllDigitsAfterSlash = false
            }
        }

        private func isCurrentTokenPath(_ nsText: NSString) -> Bool {
            guard tokenSlashCount > 0 || tokenHasBackslash else { return false }
            guard openQuote == 0 && tokenStart >= 0 && tokenSlashCount == 1 && !tokenHasBackslash else { return true }
            let beforeLen = tokenFirstSlash - tokenStart
            guard beforeLen > 0 && tokenFirstSlash + 1 < tokenEnd else { return true }
            if tokenAllDigitsBeforeSlash && tokenHasDigitAfterSlash && tokenAllDigitsAfterSlash { return false }
            return !Self.isProtocolPrefix(nsText, start: tokenStart, len: beforeLen, afterSlash: tokenFirstSlash + 1)
        }

        private static func isProtocolPrefix(_ nsText: NSString, start: Int, len: Int, afterSlash: Int) -> Bool {
            guard (len == 3 || len == 4) && CoreTelemetryService.isASCIIDigit(nsText.character(at: afterSlash)) else {
                return false
            }
            if len == 4 {
                return matchesASCIIUpper3(nsText, at: start, c0: 0x48, c1: 0x54, c2: 0x54)
                    && foldASCIIUpper(nsText.character(at: start + 3)) == 0x50
            }
            return matchesASCIIUpper3(nsText, at: start, c0: 0x54, c1: 0x4C, c2: 0x53)
                || matchesASCIIUpper3(nsText, at: start, c0: 0x53, c1: 0x53, c2: 0x4C)
        }

        private static func foldASCIIUpper(_ ch: unichar) -> unichar {
            (ch >= 0x61 && ch <= 0x7A) ? (ch - 0x20) : ch
        }

        static func matchesASCIIUpper3(
            _ nsText: NSString, at start: Int, c0: unichar, c1: unichar, c2: unichar
        ) -> Bool {
            foldASCIIUpper(nsText.character(at: start)) == c0
                && foldASCIIUpper(nsText.character(at: start + 1)) == c1
                && foldASCIIUpper(nsText.character(at: start + 2)) == c2
        }

        private static func canOpenQuote(_ nsText: NSString, at pos: Int, ch: unichar) -> Bool {
            if ch == 0x22 { return true }
            guard ch == 0x27 else { return false }
            if pos == 0 || !isLetterOrDigit(nsText.character(at: pos - 1)) { return true }
            return pos + 1 < nsText.length
                && (isFileScheme(nsText, at: pos + 1) || startsLocalPath(nsText, at: pos + 1, atTokenStart: true))
        }

        static func isInnerApostrophe(_ nsText: NSString, at pos: Int, ch: unichar) -> Bool {
            ch == 0x27 && pos > 0 && pos + 1 < nsText.length
                && isLetterOrDigit(nsText.character(at: pos - 1)) && isLetter(nsText.character(at: pos + 1))
        }

        static func isLetter(_ ch: unichar) -> Bool {
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

        private static func isTrailingSentencePunct(_ ch: unichar) -> Bool {
            ch == 0x2E || ch == 0x2C || ch == 0x3B || ch == 0x3A || ch == 0x21
                || ch == 0x3F || ch == 0x29 || ch == 0x5D || ch == 0x7D
        }

        static let localOrShareSchemes: Set<String> = [
            "file", "content", "smb", "cifs", "afp", "nfs",
            "sftp", "ftp", "ftps", "dav", "davs", "webdav", "webdavs",
        ]

        private static let localShareURIPrefixes: [[unichar]] = [
            "file://", "file:/", "content://", "smb://", "cifs://", "afp://", "nfs://",
            "sftp://", "ftps://", "ftp://", "davs://", "dav://", "webdavs://", "webdav://",
        ].map { Array($0.utf16) }

        static func isFileScheme(_ nsText: NSString, at pos: Int) -> Bool {
            localURISchemeLength(nsText, at: pos) > 0
        }

        static func localURISchemeLength(_ nsText: NSString, at pos: Int) -> Int {
            if pos > 0 && isURLSchemeChar(nsText.character(at: pos - 1)) { return 0 }
            for target in localShareURIPrefixes where matchesFoldedPrefix(nsText, at: pos, target: target) {
                return target.count
            }
            return 0
        }

        private static func matchesFoldedPrefix(_ nsText: NSString, at pos: Int, target: [unichar]) -> Bool {
            guard pos + target.count <= nsText.length else { return false }
            for offset in 0..<target.count {
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

    static func redactQuotedFilenames(in text: String) -> String {
        guard text.contains(".") || text.contains("\\u") else { return text }
        let afterDouble = text.contains("\"") ? redactDoubleQuotedFilenamesRespectingQuotes(in: text) : text
        return (afterDouble.contains("'") || afterDouble.contains("\\u"))
            ? redactSingleQuotedFilenamesRespectingQuotes(in: afterDouble)
            : afterDouble
    }

    static func redactSingleQuotedFilenamesOnSource(_ nsText: NSString, scanSource: NSString) -> String {
        let hasAt = VaultLineTracker.hasEmailAt(scanSource as String)
        let len = scanSource.length
        var result = ""
        var copied = 0
        var segStart = 0
        while segStart < len {
            var segEnd = segStart
            while segEnd < len && !isQuotedSegStop(scanSource.character(at: segEnd)) { segEnd += 1 }
            redactSingleQuotesInSegment(
                nsText, scanSource: scanSource, range: segStart..<segEnd, hasAt: hasAt, result: &result, copied: &copied
            )
            segStart = max(segEnd + 1, copied)
        }
        guard copied > 0 else { return nsText as String }
        result += nsText.substring(from: copied)
        return result
    }

    static func applySingleQuotedSpans(
        _ nsText: NSString, decoded: NSString, rawOffsets: [Int], result: inout String, copied: inout Int
    ) {
        let hasAt = VaultLineTracker.hasEmailAt(decoded as String)
        let len = decoded.length
        var decCopied = 0
        var segStart = 0
        while segStart < len {
            var segEnd = segStart
            while segEnd < len && !isQuotedSegStop(decoded.character(at: segEnd)) { segEnd += 1 }
            applySingleQuotesInDecodedSegment(
                nsText, decoded: decoded, range: segStart..<segEnd,
                rawOffsets: rawOffsets, hasAt: hasAt, result: &result, copied: &copied, decCopied: &decCopied
            )
            segStart = max(segEnd + 1, decCopied)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func applySingleQuotesInDecodedSegment(
        _ nsText: NSString, decoded: NSString, range: Range<Int>,
        rawOffsets: [Int], hasAt: Bool, result: inout String, copied: inout Int, decCopied: inout Int
    ) {
        var open = -1
        var candidateClose = -1
        for pos in range where pos >= decCopied && decoded.character(at: pos) == 0x27 {
            let isOpener = pos == range.lowerBound || !VaultLineTracker.isLetterOrDigit(decoded.character(at: pos - 1))
            if isOpener {
                if open < 0 || candidateClose >= 0 {
                    open = pos
                    candidateClose = -1
                }
            } else if open >= 0
                && (pos + 1 == range.upperBound || !VaultLineTracker.isLetterOrDigit(decoded.character(at: pos + 1)))
            {
                if endsWithFilenameExt(decoded, start: open + 1, end: pos) {
                    let emailEnd = hasAt ? VaultLineTracker.findEmailTailEnd(decoded, from: pos + 1, len: decoded.length) : -1
                    let endPos = max(pos + 1, emailEnd)
                    if result.isEmpty { result.reserveCapacity(nsText.length) }
                    result += nsText.substring(with: NSRange(location: copied, length: rawOffsets[open] - copied))
                    result += "[redacted-path]"
                    copied = rawOffsets[endPos]
                    decCopied = endPos
                    open = -1
                    candidateClose = -1
                } else {
                    candidateClose = pos
                }
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func redactSingleQuotesInSegment(
        _ nsText: NSString, scanSource: NSString, range: Range<Int>, hasAt: Bool, result: inout String, copied: inout Int
    ) {
        var open = -1
        var candidateClose = -1
        for pos in range where pos >= copied && scanSource.character(at: pos) == 0x27 {
            let isOpener = pos == range.lowerBound || !VaultLineTracker.isLetterOrDigit(scanSource.character(at: pos - 1))
            if isOpener {
                if open < 0 || candidateClose >= 0 {
                    open = pos
                    candidateClose = -1
                }
            } else if open >= 0
                && (pos + 1 == range.upperBound || !VaultLineTracker.isLetterOrDigit(scanSource.character(at: pos + 1)))
            {
                if endsWithFilenameExt(scanSource, start: open + 1, end: pos) {
                    let emailEnd =
                        hasAt ? VaultLineTracker.findEmailTailEnd(scanSource, from: pos + 1, len: scanSource.length) : -1
                    if result.isEmpty { result.reserveCapacity(nsText.length) }
                    result += nsText.substring(with: NSRange(location: copied, length: open - copied))
                    result += "[redacted-path]"
                    copied = max(pos + 1, emailEnd)
                    open = -1
                    candidateClose = -1
                } else {
                    candidateClose = pos
                }
            }
        }
    }

    static func isQuotedSegStop(_ ch: unichar) -> Bool {
        ch == 0x0A || ch == 0x0D || ch == 0x2F || ch == 0x5C || ch == 0x1E || ch == 0x1F
    }

    static func endsWithFilenameExt(_ nsText: NSString, start: Int, end: Int) -> Bool {
        var extStart = end
        while extStart > start && end - extStart < 17 {
            let ch = nsText.character(at: extStart - 1)
            if !isASCIILetter(ch) && !isASCIIDigit(ch) { break }
            extStart -= 1
        }
        let extLen = end - extStart
        return extLen >= 1 && extLen <= 16 && extStart > start && nsText.character(at: extStart - 1) == 0x2E
    }

    /// Double-quoted file:// URIs terminate at the next unescaped '"'. Unquoted and single-quoted
    /// file:// URIs fail closed to the next vaulted URL or line break so unescaped apostrophes
    /// inside filenames (e.g. "O' Connor") can never leak suffixes.
    private static func fileURISpanEnd(
        _ nsText: NSString, after schemeEnd: Int, isDoubleQuoted: Bool, limit: Int, vaultPrefix: NSString
    ) -> (rawEnd: Int, trimmedEnd: Int) {
        var rawEnd = schemeEnd
        var stoppedAtVault = false
        var escapedBackslash = false
        while rawEnd < limit {
            let ch = nsText.character(at: rawEnd)
            let atVault = ch == 0x1E && matchesPrefix(nsText, at: rawEnd, prefix: vaultPrefix)
            if ch == 0x0A || ch == 0x0D || atVault {
                stoppedAtVault = atVault
                break
            }
            if isDoubleQuoted && ch == 0x22 && !escapedBackslash {
                break
            }
            escapedBackslash = (ch == 0x5C) ? !escapedBackslash : false
            rawEnd += 1
        }
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

    static func replaceUnquotedParenPaths(in text: String, using regex: NSRegularExpression) -> String {
        guard text.contains("(") else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var copied = 0
        var cursor = 0
        var openQuote: unichar = 0
        var escapedBackslash = false
        for match in matches {
            advanceQuoteCursor(
                nsText, to: match.range.location, cursor: &cursor,
                openQuote: &openQuote, escapedBackslash: &escapedBackslash
            )
            if openQuote == 0 {
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copied, length: match.range.location - copied))
                result += "([redacted-path])"
                copied = match.range.location + match.range.length
            }
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func advanceQuoteCursor(
        _ nsText: NSString, to target: Int, cursor: inout Int,
        openQuote: inout unichar, escapedBackslash: inout Bool
    ) {
        while cursor < target {
            let ch = nsText.character(at: cursor)
            if ch == 0x0A || ch == 0x0D {
                openQuote = 0
                escapedBackslash = false
            } else if !escapedBackslash && openQuote != 0 && ch == openQuote
                && !VaultLineTracker.isInnerApostrophe(nsText, at: cursor, ch: ch)
            {
                openQuote = 0
            } else if !escapedBackslash && openQuote == 0 && canOpenSimpleQuote(nsText, at: cursor, ch: ch) {
                openQuote = ch
            }
            escapedBackslash = (ch == 0x5C) && !escapedBackslash
            cursor += 1
        }
    }

    private static func canOpenSimpleQuote(_ nsText: NSString, at pos: Int, ch: unichar) -> Bool {
        if ch == 0x22 { return true }
        return ch == 0x27 && (pos == 0 || !VaultLineTracker.isLetterOrDigit(nsText.character(at: pos - 1)))
    }

    static func redactFileURIs(in text: String, vaultPrefix: String) -> String {
        let nsText = text as NSString
        let nsPrefix = vaultPrefix as NSString
        let totalLength = nsText.length
        guard totalLength >= 6 else { return text }
        var checkedQuotes = false
        var quoteSpans: [QuotedPathSpan]?
        var spanIdx = 0
        var result = ""
        var copyStart = 0
        var pos = 0
        while pos < totalLength {
            let schemeLen = VaultLineTracker.localURISchemeLength(nsText, at: pos)
            if schemeLen > 0 {
                if !checkedQuotes {
                    checkedQuotes = true
                    if text.contains("\"") { quoteSpans = collectBalancedDoubleQuoteSpans(nsText) }
                }
                let (isDoubleQuoted, scanLimit) = CoreTelemetryQuotedPathHelpers.resolveFileURIQuoteBounds(
                    nsText, pos: pos, spans: quoteSpans, spanIdx: &spanIdx
                )
                let (rawEnd, trimmedEnd) = fileURISpanEnd(
                    nsText, after: pos + schemeLen, isDoubleQuoted: isDoubleQuoted, limit: scanLimit, vaultPrefix: nsPrefix
                )
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

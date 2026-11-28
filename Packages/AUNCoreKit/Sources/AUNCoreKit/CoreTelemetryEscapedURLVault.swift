import Foundation

extension CoreTelemetryService {
    static func formatVaultedURLAndTail(
        _ nsText: NSString, span: URLScanMatch, baseURL: String, inSingleQuote: Bool
    ) -> (String, String) {
        if span.hasQueryOrFragment {
            let qf = nsText.substring(with: NSRange(location: span.baseEnd, length: span.totalEnd - span.baseEnd))
            let (cleanQF, trimmedTail) = trimQueryOrFragmentDelimiters(
                qf, nsText: nsText, matchStart: span.start, inSingleQuote: inSingleQuote
            )
            let marker = cleanQF.first.map(String.init) ?? "?"
            return ("\(baseURL)\(marker)[redacted]", trimmedTail)
        }
        return trimTrailingURLDelimiters(baseURL, nsText: nsText, matchStart: span.start, inSingleQuote: inSingleQuote)
    }

    static func isAngleWrappedBefore(_ nsText: NSString, urlStart: Int) -> Bool {
        if urlStart > 0 && nsText.character(at: urlStart - 1) == 0x3C { return true }
        guard urlStart >= 6 else { return false }
        let last = nsText.character(at: urlStart - 1)
        return nsText.character(at: urlStart - 6) == 0x5C
            && nsText.character(at: urlStart - 5) == 0x75
            && nsText.character(at: urlStart - 4) == 0x30
            && nsText.character(at: urlStart - 3) == 0x30
            && nsText.character(at: urlStart - 2) == 0x33
            && (last == 0x63 || last == 0x43)
            && !VaultLineTracker.isPrecededByOddBackslashes(nsText, at: urlStart - 6, minPos: 0)
    }

    static func isEscapedGreater(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        guard pos + 5 < len && nsText.character(at: pos) == 0x5C && nsText.character(at: pos + 1) == 0x75 else {
            return false
        }
        let last = nsText.character(at: pos + 5)
        return nsText.character(at: pos + 2) == 0x30
            && nsText.character(at: pos + 3) == 0x30
            && nsText.character(at: pos + 4) == 0x33
            && (last == 0x65 || last == 0x45)
            && !VaultLineTracker.isPrecededByOddBackslashes(nsText, at: pos, minPos: 0)
    }

    static func stepJsonEscapeBeforeScheme(_ nsText: NSString, start: Int, sep: Int, minStart: Int) -> (Int, Bool) {
        var cur = start
        var stepped = false
        while cur < sep && cur > minStart && nsText.character(at: cur - 1) == 0x5C
            && !VaultLineTracker.isPrecededByOddBackslashes(nsText, at: cur - 1, minPos: minStart)
        {
            let esc = nsText.character(at: cur)
            if esc == 0x6E || esc == 0x72 || esc == 0x74 || esc == 0x62 || esc == 0x66 {
                cur += 1
                stepped = true
                continue
            }
            if esc == 0x75 && cur + 5 <= sep, let code = parseHex4(nsText, pos: cur + 1),
                !VaultLineTracker.isURLSchemeChar(code) && code != 0x2F && code != 0x5C
            {
                cur += 5
                stepped = true
                continue
            }
            break
        }
        return (cur, stepped)
    }

    static func computeQueryAngleStopMask(_ nsText: NSString, urlStart: Int, inDoubleQuote: Bool) -> Int {
        let wrappedInAngle = isAngleWrappedBefore(nsText, urlStart: urlStart)
        let stopOnLess = !inDoubleQuote && !wrappedInAngle
        let stopOnGreater = !inDoubleQuote || wrappedInAngle
        return (stopOnLess ? 1 : 0) | (stopOnGreater ? 2 : 0) | (inDoubleQuote ? 4 : 0) | (wrappedInAngle ? 8 : 0)
    }

    static func emailUnicodeAtLength(_ nsText: NSString, at pos: Int, len: Int) -> Int {
        guard
            pos + 5 < len && nsText.character(at: pos) == 0x5C
                && nsText.character(at: pos + 1) == 0x75
                && nsText.character(at: pos + 2) == 0x30
                && nsText.character(at: pos + 3) == 0x30
                && nsText.character(at: pos + 4) == 0x34
                && nsText.character(at: pos + 5) == 0x30
                && !VaultLineTracker.isPrecededByOddBackslashes(nsText, at: pos, minPos: 0)
        else { return 0 }
        return 6
    }

    static func classifyEscapedDomainChar(_ nsText: NSString, at pos: Int, len: Int) -> (VaultLineTracker.DomainCharKind, Int)? {
        guard pos + 5 < len && nsText.character(at: pos) == 0x5C && nsText.character(at: pos + 1) == 0x75,
            let code = parseHex4(nsText, pos: pos + 2)
        else { return nil }
        if code < 0x80 {
            if isASCIILetter(code) { return (.letter, 6) }
            if isASCIIDigit(code) { return (.digit, 6) }
            if code == 0x2E { return (.dot, 6) }
            return (code == 0x2D ? .hyphen : .other, 6)
        }
        if VaultLineTracker.isEmailDomainDot(code) { return (.dot, 6) }
        if code >= 0xD800 && code <= 0xDBFF {
            return classifyEscapedSurrogateDomainChar(nsText, at: pos, len: len, high: code)
        }
        if let scalar = UnicodeScalar(code) {
            return (classifyDomainScalar(scalar), 6)
        }
        return (.other, 6)
    }

    private static func classifyEscapedSurrogateDomainChar(
        _ nsText: NSString, at pos: Int, len: Int, high: unichar
    ) -> (VaultLineTracker.DomainCharKind, Int) {
        guard pos + 11 < len && nsText.character(at: pos + 6) == 0x5C && nsText.character(at: pos + 7) == 0x75,
            let low = parseHex4(nsText, pos: pos + 8), low >= 0xDC00 && low <= 0xDFFF,
            let scalar = UnicodeScalar(0x10000 + ((Int(high) - 0xD800) << 10) + (Int(low) - 0xDC00))
        else { return (.other, 6) }
        return (classifyDomainScalar(scalar), 12)
    }

    private static func classifyDomainScalar(_ scalar: UnicodeScalar) -> VaultLineTracker.DomainCharKind {
        if CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) { return .letter }
        return CharacterSet.decimalDigits.contains(scalar) ? .digit : .other
    }

    static func isValidDomainLabelEnd(
        _ nsText: NSString, labelStart: Int, end: Int, labelHasLetter: Bool, endedHyphen: Bool
    ) -> Bool {
        let len = nsText.length
        guard end > labelStart, labelHasLetter, !endedHyphen else { return false }
        if end < len {
            let (kind, dotStep) = VaultLineTracker.classifyDomainChar(nsText, at: end, len: len)
            if kind == .letter || kind == .digit || kind == .hyphen || nsText.character(at: end) == 0x5F {
                return false
            }
            if kind == .dot && end + dotStep < len {
                let (nextKind, _) = VaultLineTracker.classifyDomainChar(nsText, at: end + dotStep, len: len)
                if nextKind == .letter || nextKind == .digit { return false }
            }
        }
        return true
    }

    static func redactEmailsInEscapedDoubleQuotes(in text: String, quotedOnly: Bool) -> String {
        guard text.contains("\"") && text.contains("\\") && (VaultLineTracker.hasEmailAt(text) || text.contains("\\u")) else {
            return text
        }
        let nsText = text as NSString
        let spans = collectBalancedDoubleQuoteSpans(nsText)
        guard !spans.isEmpty else { return text }
        var result = ""
        var copied = 0
        for span in spans {
            let innerStart = span.open + 1
            guard innerStart < span.close,
                nsText.range(of: "\\", options: [], range: NSRange(location: innerStart, length: span.close - innerStart))
                    .location
                    != NSNotFound
            else { continue }
            let (decoded, rawOffsets) = decodeQuotedSpanWithOffsets(nsText, start: innerStart, end: span.close)
            guard VaultLineTracker.hasEmailAt(decoded) && (!quotedOnly || decoded.contains("\"")) else { continue }
            for (mStart, mEnd) in findEmailMatchRanges(in: decoded, quotedOnly: quotedOnly) {
                let rawStart = rawOffsets[mStart]
                let rawEnd = rawOffsets[mEnd]
                guard rawStart >= copied else { continue }
                if result.isEmpty { result.reserveCapacity(text.count) }
                result += nsText.substring(with: NSRange(location: copied, length: rawStart - copied))
                result += "[redacted-email]"
                copied = rawEnd
            }
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func findEmailMatchRanges(in text: String, quotedOnly: Bool) -> [(Int, Int)] {
        let nsText = text as NSString
        let len = nsText.length
        var ranges: [(Int, Int)] = []
        var copied = 0
        var idx = 0
        var cacheUntil = -1
        var cachedClose = -1
        while idx < len {
            if nsText.character(at: idx) == 0x22
                && !VaultLineTracker.isPrecededByOddBackslashes(nsText, at: idx, minPos: copied)
            {
                if let qEnd = VaultLineTracker.matchQuotedEmailEnd(
                    nsText, at: idx, cacheUntil: &cacheUntil, cachedClose: &cachedClose
                ) {
                    ranges.append((idx, qEnd))
                    copied = qEnd
                    idx = qEnd
                    cacheUntil = -1
                    continue
                }
                idx += 1
                continue
            }
            if quotedOnly {
                idx += 1
                continue
            }
            let atLen = VaultLineTracker.emailAtLength(nsText, at: idx, len: len)
            if atLen == 0 {
                idx += 1
                continue
            }
            let reqDot = idx > copied && nsText.character(at: idx - 1) == 0x2F
            let domEnd = VaultLineTracker.findEmailDomainEnd(nsText, domStart: idx + atLen, len: len, requireDot: reqDot)
            let localStart = domEnd > 0 ? VaultLineTracker.findEmailLocalStart(nsText, at: idx, minPos: copied, len: len) : idx
            if domEnd > 0 && localStart < idx {
                ranges.append((localStart, domEnd))
                copied = domEnd
                idx = domEnd
                cacheUntil = -1
            } else {
                idx += atLen
            }
        }
        return ranges
    }

    // swiftlint:disable:next function_parameter_count
    static func emitSimpleVaultedURL(
        _ nsText: NSString,
        span: URLScanMatch,
        quoteState: Int,
        urls: (base: String, redacted: String, tail: String),
        unclosedAngleLineEnd: inout Int,
        prefix: String,
        vaultedURLs: inout [String]
    ) -> (token: String, endPos: Int, finalTail: String) {
        let quotedSecret = resolveQuotedSecretURLTail(
            nsText, span: span, inDoubleQuote: (quoteState & 2) != 0,
            rawURL: urls.base, redactedURL: urls.redacted,
            unclosedAngleLineEnd: &unclosedAngleLineEnd
        )
        let idx = vaultedURLs.count
        vaultedURLs.append(quotedSecret?.redacted ?? urls.redacted)
        let emitTail = quotedSecret != nil ? "" : urls.tail
        return ("\(prefix)\(idx)\u{001F}\(emitTail)", quotedSecret?.endPos ?? span.totalEnd, emitTail)
    }

    // swiftlint:disable:next function_parameter_count
    static func resolveQuotedSecretURLTail(
        _ nsText: NSString, span: URLScanMatch, inDoubleQuote: Bool, rawURL: String, redactedURL: String,
        unclosedAngleLineEnd: inout Int
    ) -> (redacted: String, endPos: Int)? {
        let len = nsText.length
        let wrappedInAngle = isAngleWrappedBefore(nsText, urlStart: span.start)
        guard !span.hasQueryOrFragment && (inDoubleQuote || wrappedInAngle) && span.totalEnd < len else { return nil }
        guard inDoubleQuote || span.totalEnd >= unclosedAngleLineEnd else { return nil }
        let nextCh = nsText.character(at: span.totalEnd)
        guard
            nextCh != 0x0A && nextCh != 0x0D
                && (!inDoubleQuote || nextCh != 0x22)
                && (!wrappedInAngle || (nextCh != 0x3E && !isEscapedGreater(nsText, at: span.totalEnd, len: len)))
        else { return nil }
        guard let secretURL = resolveSecretURLPrefix(rawURL: rawURL, redactedURL: redactedURL) else { return nil }
        var pos = span.totalEnd
        var escaped = false
        var stoppedAtAngle = false
        while pos < len {
            let ch = nsText.character(at: pos)
            if ch == 0x0A || ch == 0x0D || (inDoubleQuote && ch == 0x22 && !escaped) { break }
            if wrappedInAngle && !escaped && (ch == 0x3E || isEscapedGreater(nsText, at: pos, len: len)) {
                stoppedAtAngle = true
                break
            }
            escaped = inDoubleQuote && (ch == 0x5C) && !escaped
            pos += 1
        }
        if !inDoubleQuote && !stoppedAtAngle {
            if pos > unclosedAngleLineEnd { unclosedAngleLineEnd = pos }
            return nil
        }
        return (secretURL, pos)
    }

    private static func resolveSecretURLPrefix(rawURL: String, redactedURL: String) -> String? {
        if redactedURL != rawURL && redactedURL.hasSuffix("[redacted]") { return redactedURL }
        let probeInput = rawURL + "x"
        let probe = redactURLPathSecrets(probeInput)
        return (probe != probeInput && probe.hasSuffix("[redacted]")) ? probe : nil
    }

    static func extendSpacedQuotedURLQuery(
        _ nsText: NSString, input: URLContinuationInput, failedSpacedContMax: inout Int
    ) -> URLContinuationResult? {
        let span = input.span
        let len = nsText.length
        let inDoubleQuote = input.inDoubleQuote
        let wrappedInAngle = isAngleWrappedBefore(nsText, urlStart: span.start)
        guard !span.hasQueryOrFragment && (inDoubleQuote || wrappedInAngle) && span.totalEnd < len else { return nil }
        let firstCh = nsText.character(at: span.totalEnd)
        guard
            firstCh != 0x0A && firstCh != 0x0D
                && (!inDoubleQuote || firstCh != 0x22)
                && (!wrappedInAngle || (firstCh != 0x3E && !isEscapedGreater(nsText, at: span.totalEnd, len: len)))
                && span.totalEnd >= failedSpacedContMax
        else { return nil }
        let urlStartsSpan = wrappedInAngle || isURLAtDoubleQuoteStart(nsText, urlStart: span.start)
        var pos = span.totalEnd
        while pos < len {
            let step = stepSpacedQuotedURLPos(
                nsText, pos: pos, len: len, span: span,
                flags: (inDoubleQuote, wrappedInAngle, urlStartsSpan)
            )
            if step == -1 { break }
            if step == -2 {
                return buildSpacedURLQueryResult(nsText, input: input, qfPos: pos)
            }
            pos = step
        }
        if pos > failedSpacedContMax { failedSpacedContMax = pos }
        return nil
    }

    private static func stepSpacedQuotedURLPos(
        _ nsText: NSString, pos: Int, len: Int, span: URLScanMatch,
        flags: (inDoubleQuote: Bool, wrappedInAngle: Bool, urlStartsSpan: Bool)
    ) -> Int {
        let ch = nsText.character(at: pos)
        if ch == 0x0A || ch == 0x0D || (flags.inDoubleQuote && ch == 0x22) { return -1 }
        if flags.wrappedInAngle && (ch == 0x3E || isEscapedGreater(nsText, at: pos, len: len)) { return -1 }
        if VaultLineTracker.isFileScheme(nsText, at: pos)
            || isURLWindowsDriveStop(nsText, at: pos, len: len)
        {
            return -1
        }
        if pos > span.totalEnd && isSpacedURLSchemeStart(nsText, at: pos, len: len) { return -1 }
        if flags.inDoubleQuote && ch == 0x5C && pos + 1 < len {
            return stepSpacedQuotedEscape(nsText, pos: pos, len: len, wrappedInAngle: flags.wrappedInAngle)
        }
        if (ch == 0x3F || ch == 0x23)
            && isValidSpacedURLQueryStart(nsText, qfPos: pos, minPos: span.totalEnd, flags: flags)
        {
            return -2
        }
        return pos + 1
    }

    private static func stepSpacedQuotedEscape(_ nsText: NSString, pos: Int, len: Int, wrappedInAngle: Bool) -> Int {
        let esc = nsText.character(at: pos + 1)
        if esc == 0x72 || esc == 0x6E { return -1 }
        if esc == 0x75 && pos + 5 < len, let code = parseHex4(nsText, pos: pos + 2) {
            if code == 0x0A || code == 0x0D || (wrappedInAngle && code == 0x3E) { return -1 }
            return pos + 6
        }
        return pos + 2
    }

    private static func isSpacedURLSchemeStart(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        let prev = nsText.character(at: pos - 1)
        guard !VaultLineTracker.isURLSchemeChar(prev) && prev != 0x2F && prev != 0x5C else { return false }
        guard isASCIILetter(nsText.character(at: pos)) else { return false }
        var idx = pos + 1
        while idx < len && VaultLineTracker.isURLSchemeChar(nsText.character(at: idx)) { idx += 1 }
        return idx - pos >= 2 && idx + 2 < len
            && nsText.character(at: idx) == 0x3A
            && nsText.character(at: idx + 1) == 0x2F
            && nsText.character(at: idx + 2) == 0x2F
    }

    private static func isValidSpacedURLQueryStart(
        _ nsText: NSString, qfPos: Int, minPos: Int,
        flags: (inDoubleQuote: Bool, wrappedInAngle: Bool, urlStartsSpan: Bool)
    ) -> Bool {
        let len = nsText.length
        let nextPos = qfPos + 1
        guard nextPos < len else { return false }
        let nextCh = nsText.character(at: nextPos)
        guard
            nextCh != 0x0A && nextCh != 0x0D
                && (!flags.inDoubleQuote || nextCh != 0x22)
                && (!flags.wrappedInAngle || (nextCh != 0x3E && !isEscapedGreater(nsText, at: nextPos, len: len)))
        else { return false }
        let nextIsWS =
            VaultLineTracker.isWhitespace(nextCh)
            || (flags.inDoubleQuote && isJsonWhitespaceEscape(nsText, at: nextPos, len: len))
        if nsText.character(at: qfPos) == 0x3F { return !nextIsWS || flags.urlStartsSpan }
        return !nextIsWS
            && (flags.urlStartsSpan
                || !isPrecededBySpaceOrEscape(nsText, at: qfPos, minPos: minPos, inDoubleQuote: flags.inDoubleQuote))
    }

    private static func isURLAtDoubleQuoteStart(_ nsText: NSString, urlStart: Int) -> Bool {
        var pos = urlStart
        while pos > 0 {
            let prev = nsText.character(at: pos - 1)
            if VaultLineTracker.isWhitespace(prev) && prev != 0x0A && prev != 0x0D {
                pos -= 1
            } else if pos >= 2 && nsText.character(at: pos - 2) == 0x5C && prev == 0x74
                && !VaultLineTracker.isPrecededByOddBackslashes(nsText, at: pos - 2, minPos: 0)
            {
                pos -= 2
            } else if pos >= 6 && nsText.character(at: pos - 6) == 0x5C && nsText.character(at: pos - 5) == 0x75
                && !VaultLineTracker.isPrecededByOddBackslashes(nsText, at: pos - 6, minPos: 0),
                let code = parseHex4(nsText, pos: pos - 4),
                VaultLineTracker.isWhitespace(code) && code != 0x0A && code != 0x0D
            {
                pos -= 6
            } else {
                return prev == 0x22 && !VaultLineTracker.isPrecededByOddBackslashes(nsText, at: pos - 1, minPos: 0)
            }
        }
        return false
    }

    private static func isJsonWhitespaceEscape(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        guard nsText.character(at: pos) == 0x5C && pos + 1 < len else { return false }
        let esc = nsText.character(at: pos + 1)
        if esc == 0x74 || esc == 0x72 || esc == 0x6E { return true }
        guard esc == 0x75 && pos + 5 < len, let code = parseHex4(nsText, pos: pos + 2) else { return false }
        return VaultLineTracker.isWhitespace(code)
    }

    private static func isPrecededBySpaceOrEscape(_ nsText: NSString, at pos: Int, minPos: Int, inDoubleQuote: Bool) -> Bool {
        guard pos > minPos else { return false }
        if VaultLineTracker.isWhitespace(nsText.character(at: pos - 1)) { return true }
        guard inDoubleQuote else { return false }
        if pos - 2 >= minPos && nsText.character(at: pos - 2) == 0x5C && nsText.character(at: pos - 1) == 0x74
            && !VaultLineTracker.isPrecededByOddBackslashes(nsText, at: pos - 2, minPos: minPos)
        {
            return true
        }
        guard
            pos - 6 >= minPos && nsText.character(at: pos - 6) == 0x5C && nsText.character(at: pos - 5) == 0x75
                && !VaultLineTracker.isPrecededByOddBackslashes(nsText, at: pos - 6, minPos: minPos),
            let code = parseHex4(nsText, pos: pos - 4)
        else { return false }
        return VaultLineTracker.isWhitespace(code)
    }

    private static func buildSpacedURLQueryResult(
        _ nsText: NSString, input: URLContinuationInput, qfPos: Int
    ) -> URLContinuationResult {
        let span = input.span
        let angleMask = computeQueryAngleStopMask(nsText, urlStart: span.start, inDoubleQuote: input.inDoubleQuote)
        let qfEnd = scanQueryOrFragment(nsText, start: qfPos, len: nsText.length, angleStopMask: angleMask)
        let qf = nsText.substring(with: NSRange(location: qfPos, length: qfEnd - qfPos))
        let (cleanQF, qfTail) = trimQueryOrFragmentDelimiters(
            qf, nsText: nsText, matchStart: span.start, inSingleQuote: input.inSingleQuote
        )
        let qfToken = "\(cleanQF.first.map(String.init) ?? "?")[redacted]"
        if let secretPrefix = resolveSecretURLPrefix(rawURL: input.rawURL, redactedURL: redactURLPathSecrets(input.rawURL)) {
            return URLContinuationResult(
                replaceBase: true, baseURL: "\(secretPrefix)\(qfToken)", keepBaseTail: false,
                middle: "", qfToken: "", tail: qfTail, endPos: qfEnd
            )
        }
        let middle = nsText.substring(with: NSRange(location: span.totalEnd, length: qfPos - span.totalEnd))
        return URLContinuationResult(
            replaceBase: false, baseURL: "", keepBaseTail: !input.baseTail.isEmpty,
            middle: middle, qfToken: qfToken, tail: qfTail, endPos: qfEnd
        )
    }

    private static let escVaultPrefix = "\u{001E}AUNESC"

    static func vaultJsonEscapedURLsInBalancedQuotes(
        _ text: String, prefix: String, vaultedURLs: inout [String]
    ) -> String {
        guard text.contains("\"") && (text.contains("\\/") || text.contains("\\u")) else { return text }
        let nsText = text as NSString
        let spans = collectBalancedDoubleQuoteSpans(nsText)
        guard !spans.isEmpty else { return text }
        var result = ""
        var copied = 0
        for span in spans {
            let innerStart = span.open + 1
            guard innerStart < span.close && containsSlashOrUnicodeEscape(nsText, start: innerStart, end: span.close) else {
                continue
            }
            let norm = decodeURLEscapesForVault(nsText, start: innerStart, end: span.close)
            guard norm.contains("://") else { continue }
            var innerVaulted: [String] = []
            let innerResult = vaultNonFileURLsInto("\"\(norm)\"", prefix: escVaultPrefix, vaultedURLs: &innerVaulted)
            guard !innerVaulted.isEmpty else { continue }
            if result.isEmpty { result.reserveCapacity(text.count) }
            result += nsText.substring(with: NSRange(location: copied, length: innerStart - copied))
            if innerVaulted.count == 1 && innerResult == "\"\(escVaultPrefix)0\u{001F}\"" && innerVaulted[0] == norm {
                let idx = vaultedURLs.count
                vaultedURLs.append(nsText.substring(with: NSRange(location: innerStart, length: span.close - innerStart)))
                result += "\(prefix)\(idx)\u{001F}"
            } else {
                let nsInner = innerResult as NSString
                appendRemappedEscapedVault(
                    nsInner, start: 1, end: nsInner.length - 1, prefix: prefix,
                    vaultedURLs: &vaultedURLs, innerVaulted: innerVaulted, result: &result
                )
            }
            copied = span.close
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    // swiftlint:disable:next function_parameter_count
    private static func appendRemappedEscapedVault(
        _ nsText: NSString, start: Int, end: Int, prefix: String,
        vaultedURLs: inout [String], innerVaulted: [String], result: inout String
    ) {
        var pos = start
        let escPrefixLen = (escVaultPrefix as NSString).length
        while pos < end {
            let found = nsText.range(of: escVaultPrefix, options: [], range: NSRange(location: pos, length: end - pos))
            if found.location == NSNotFound {
                result += nsText.substring(with: NSRange(location: pos, length: end - pos))
                break
            }
            result += nsText.substring(with: NSRange(location: pos, length: found.location - pos))
            let numStart = found.location + escPrefixLen
            let numEnd = CoreTelemetryQuotedPathHelpers.scanVaultIndexEnd(nsText, from: numStart, limit: end)
            if numEnd > numStart,
                let innerIdx = Int(nsText.substring(with: NSRange(location: numStart, length: numEnd - numStart))),
                innerIdx >= 0 && innerIdx < innerVaulted.count
            {
                let globalIdx = vaultedURLs.count
                vaultedURLs.append(innerVaulted[innerIdx])
                result += "\(prefix)\(globalIdx)\u{001F}"
                pos = numEnd + 1
            } else {
                result += escVaultPrefix
                pos = numStart
            }
        }
    }

    private static func containsSlashOrUnicodeEscape(_ nsText: NSString, start: Int, end: Int) -> Bool {
        var idx = start
        while idx < end {
            if nsText.character(at: idx) == 0x5C && idx + 1 < end {
                let next = nsText.character(at: idx + 1)
                if next == 0x2F || (next == 0x75 && idx + 5 < end) { return true }
                idx += 2
                continue
            }
            idx += 1
        }
        return false
    }

    private static func isURLStructuralEscape(_ ch: unichar) -> Bool {
        if ch <= 0x20 || (ch >= 0x7F && ch <= 0x9F) || (ch >= 0xD800 && ch <= 0xDFFF) { return false }
        if let scalar = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
        return ch != 0x22 && ch != 0x5C && ch != 0x3C && ch != 0x3E
    }

    private static func decodeURLEscapesForVault(_ nsText: NSString, start: Int, end: Int) -> String {
        var units: [unichar] = []
        units.reserveCapacity(end - start)
        var pos = start
        while pos < end {
            let ch = nsText.character(at: pos)
            if ch == 0x5C && pos + 1 < end {
                let next = nsText.character(at: pos + 1)
                if next == 0x2F {
                    units.append(0x2F)
                    pos += 2
                    continue
                }
                if next == 0x75 && pos + 5 < end, let code = parseHex4(nsText, pos: pos + 2) {
                    if code == 0x22 {
                        units.append(0x5C)
                        units.append(0x22)
                        pos += 6
                        continue
                    }
                    if isURLStructuralEscape(code) {
                        units.append(code)
                        pos += 6
                        continue
                    }
                }
                units.append(ch)
                units.append(next)
                pos += 2
                continue
            }
            units.append(ch)
            pos += 1
        }
        return String(utf16CodeUnits: units, count: units.count)
    }
}

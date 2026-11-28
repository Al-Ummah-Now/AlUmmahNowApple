import Foundation

/// Linear O(n) auth-header scanner (plain text, JSON escaped keys, arrays) and RFC 7617 Basic / Bearer redactor.
enum CoreTelemetryAuthScanner {
    static let knownAuthSchemes = [
        "Bearer", "Basic", "Digest", "Token", "Api-Key", "ApiKey",
        "OAuth", "Negotiate", "Mutual", "HOBA", "Vapid", "SCRAM-SHA-256", "AWS4-HMAC-SHA256",
    ]

    static let basicTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern:
            #"\b(Basic)[\s\p{Zs}]+(?:("|'|\\"|\\u0022)([A-Za-z0-9+/_-]{2,}={0,2})"#
            + #"(?![A-Za-z0-9+/_=-])(\2|\\"|\\u0022|(?=[\t\p{Zs}]*(?:\r|\n|$)))|"#
            + #"([A-Za-z0-9+/_-]{2,}={0,2})(?![A-Za-z0-9+/_=-]))"#,
        options: [.caseInsensitive]
    )

    static func redactAuthCredentials(in text: String) -> String {
        var result = redactAuthHeaders(in: text)
        result = redactEscapedBasicInBalancedQuotes(in: result)
        result = redactBasicTokens(in: result)
        result = redactBearerTokens(in: result)
        return redactEscapedBearerInBalancedQuotes(in: result)
    }

    struct AuthScanState {
        var result = ""
        var copied = 0
        var edits: [(Int, Int, String)]?
        var validJsonValueEnd: [Int: Int] = [:]
        var closeToOpenMap: [Int: Int] = [:]
        var memberCommaOpen: [Int: Int] = [:]
        var arrayCommaOpen: [Int: Int] = [:]
        var containerAuthState: [Int: Int] = [:]
        var escapedContainerEnd: [Int: Int] = [:]
        var allowTrailingProse = false
        var failedContainerBack = -1

        mutating func appendRedacted(_ nsText: NSString, start: Int, end: Int, replacement: String) {
            if edits != nil {
                edits?.append((start, end, replacement))
                copied = end
                return
            }
            if result.isEmpty { result.reserveCapacity(nsText.length) }
            result += nsText.substring(with: NSRange(location: copied, length: start - copied))
            result += replacement
            copied = end
        }
    }

    struct AuthValueContext {
        let isJsonMember: Bool
        let allowTruncatedObj: Bool
        let failedTopEnd: Int
    }

    private struct AuthKeyMatch {
        let keyStart: Int
        let keyEnd: Int
        let isJsonCandidate: Bool
        let hasJsonPrefix: Bool
        let isTupleCandidate: Bool
        let failedTopEnd: Int
        let normalizedKey: String?
    }

    private static func mayContainAuthHeader(_ text: String) -> Bool {
        text.contains(":") || text.contains("=") || text.contains("\\u") || (text.contains("[") && text.contains(","))
    }

    private static func redactAuthHeaders(in text: String, maxDepth: Int = 4) -> String {
        guard mayContainAuthHeader(text) else { return text }
        let nsText = text as NSString
        var state = AuthScanState()
        scanAuthHeaders(nsText, maxDepth: maxDepth, state: &state)
        guard state.copied > 0 else { return text }
        state.result += nsText.substring(from: state.copied)
        return state.result
    }

    static func scanAuthHeaders(_ nsText: NSString, maxDepth: Int, state: inout AuthScanState) {
        let len = nsText.length
        state.allowTrailingProse = maxDepth < 4
        var idx = 0
        while idx < len {
            guard let keyMatch = matchAuthHeaderKey(nsText, at: idx, len: len, state: &state) else {
                if nsText.character(at: idx) == 0x5C && idx + 1 < len && nsText.character(at: idx + 1) == 0x22
                    && !CoreTelemetryService.VaultLineTracker.isPrecededByOddBackslashes(nsText, at: idx, minPos: state.copied),
                    let escEnd = tryRedactEscapedQuotedAuthHeader(nsText, at: idx, len: len, state: &state)
                {
                    idx = escEnd
                    continue
                }
                if maxDepth > 0 && nsText.character(at: idx) == 0x22
                    && !CoreTelemetryService.VaultLineTracker.isPrecededByOddBackslashes(nsText, at: idx, minPos: state.copied),
                    let close = findDoubleQuotedSpanEnd(nsText, open: idx, len: len)
                {
                    let changed = redactAuthHeadersInBalancedSpan(
                        nsText, innerStart: idx + 1, close: close, nextDepth: maxDepth - 1, state: &state)
                    let reenterClose =
                        !changed && !isJsonStringStartBoundary(nsText, open: idx)
                        && isJsonStringStartBoundary(nsText, open: close)
                    idx = reenterClose ? close : close + 1
                    continue
                }
                idx += 1
                continue
            }
            let allowNl = keyMatch.isJsonCandidate || keyMatch.hasJsonPrefix || keyMatch.isTupleCandidate
            let sep = skipAuthWhitespace(nsText, from: keyMatch.keyEnd, len: len, allowNewlines: allowNl)
            guard let (sepLen, isColon) = matchAuthSeparator(nsText, at: sep, len: len) else {
                if keyMatch.isTupleCandidate && sep < len && nsText.character(at: sep) == 0x2C,
                    let tupleValStart = resolveJsonTupleValueStart(nsText, afterComma: sep + 1, len: len, state: &state)
                {
                    if let normalized = keyMatch.normalizedKey {
                        let quote = nsText.substring(with: NSRange(location: keyMatch.keyStart, length: 1))
                        state.appendRedacted(
                            nsText, start: keyMatch.keyStart, end: keyMatch.keyEnd, replacement: "\(quote)\(normalized)\(quote)")
                    }
                    let tupleCtx = AuthValueContext(isJsonMember: true, allowTruncatedObj: false, failedTopEnd: -1)
                    idx = redactAuthHeaderValue(nsText, valStart: tupleValStart, ctx: tupleCtx, state: &state)
                    continue
                }
                idx = keyMatch.keyEnd
                continue
            }
            let ctx = AuthValueContext(
                isJsonMember: keyMatch.isJsonCandidate && isColon && sepLen == 1,
                allowTruncatedObj: keyMatch.hasJsonPrefix && isColon && sepLen == 1,
                failedTopEnd: isColon && sepLen == 1 ? keyMatch.failedTopEnd : -1
            )
            let valStart = skipAuthWhitespace(
                nsText, from: sep + sepLen, len: len, allowNewlines: ctx.isJsonMember || ctx.allowTruncatedObj
            )
            guard valStart < len && !isNewline(nsText.character(at: valStart)) else {
                idx = sep + sepLen
                continue
            }
            if let normalized = keyMatch.normalizedKey {
                let quote = nsText.substring(with: NSRange(location: keyMatch.keyStart, length: 1))
                state.appendRedacted(
                    nsText, start: keyMatch.keyStart, end: keyMatch.keyEnd, replacement: "\(quote)\(normalized)\(quote)")
            }
            idx = redactAuthHeaderValue(nsText, valStart: valStart, ctx: ctx, state: &state)
        }
    }

    private static let unquotedAuthHeaderNames = [
        "proxy-authorization", "authorization", "set-cookie", "cookie",
        "x-api-key", "api-key", "x-auth-token", "x-access-token", "x-api-token",
    ]

    private static func matchAuthHeaderKey(
        _ nsText: NSString, at pos: Int, len: Int, state: inout AuthScanState
    ) -> AuthKeyMatch? {
        let ch = nsText.character(at: pos)
        if ch == 0x22 || ch == 0x27 {
            return matchQuotedAuthKey(nsText, at: pos, quote: ch, state: &state)
        }
        if pos > 0 && isAuthKeyWordChar(nsText.character(at: pos - 1)) { return nil }
        for name in unquotedAuthHeaderNames {
            let nameLen = name.utf16.count
            if matchesASCII(nsText, at: pos, literal: name, len: len),
                pos + nameLen == len || !isAuthKeyWordChar(nsText.character(at: pos + nameLen))
            {
                return AuthKeyMatch(
                    keyStart: pos, keyEnd: pos + nameLen, isJsonCandidate: false,
                    hasJsonPrefix: false, isTupleCandidate: false, failedTopEnd: -1, normalizedKey: nil
                )
            }
        }
        return nil
    }

    private static func matchQuotedAuthKey(
        _ nsText: NSString, at pos: Int, quote: unichar, state: inout AuthScanState
    ) -> AuthKeyMatch? {
        let len = nsText.length
        var core: [unichar] = []
        core.reserveCapacity(20)
        var padState = (trailing: false, any: false)
        var sawEscape = false
        var hasInvalidJsonEscape = false
        var idx = pos + 1
        while idx < len {
            let ch = nsText.character(at: idx)
            if ch < 0x20 && ch != 0x09 { return nil }
            if ch == quote {
                return finishQuotedAuthKey(
                    nsText, keyRange: pos..<(idx + 1), decoded: core,
                    flags: (quote == 0x22, !hasInvalidJsonEscape, sawEscape && !padState.any), state: &state
                )
            }
            if ch == 0x5C {
                sawEscape = true
                guard let (unit, step, validJson) = decodeKeyEscape(nsText, at: idx, len: len) else { return nil }
                if !validJson { hasInvalidJsonEscape = true }
                guard appendTrimmedKeyUnit(unit, core: &core, padState: &padState) else { return nil }
                idx += step
            } else {
                guard appendTrimmedKeyUnit(ch, core: &core, padState: &padState) else { return nil }
                idx += 1
            }
        }
        return nil
    }

    private static func finishQuotedAuthKey(
        _ nsText: NSString, keyRange: Range<Int>, decoded: [unichar],
        flags: (isDoubleQuote: Bool, validEscapes: Bool, sawEscape: Bool), state: inout AuthScanState
    ) -> AuthKeyMatch? {
        guard let canonical = matchCanonicalAuthHeaderName(decoded) else { return nil }
        let hasPrefix = flags.isDoubleQuote && isPrecededByBraceOrComma(nsText, before: keyRange.lowerBound)
        let allowJson = flags.isDoubleQuote && flags.validEscapes
        let prevDelim = flags.isDoubleQuote ? skipJsonWhitespaceBackward(nsText, from: keyRange.lowerBound - 1) : -1
        let isTuple = allowJson && prevDelim >= 0 && nsText.character(at: prevDelim) == 0x5B
        let openBrace = allowJson ? findEnclosingJsonObjectStart(nsText, before: keyRange.lowerBound, state: &state) : -1
        let authState = openBrace >= 0 ? classifyTopLevelJsonContainer(nsText, openPos: openBrace, state: &state) : -1
        return AuthKeyMatch(
            keyStart: keyRange.lowerBound, keyEnd: keyRange.upperBound,
            isJsonCandidate: authState == 0, hasJsonPrefix: hasPrefix, isTupleCandidate: isTuple,
            failedTopEnd: authState > 0 ? authState : -1, normalizedKey: flags.sawEscape ? canonical : nil
        )
    }

    private static func decodeKeyEscape(_ nsText: NSString, at pos: Int, len: Int) -> (unichar, Int, Bool)? {
        guard pos + 1 < len else { return nil }
        let next = nsText.character(at: pos + 1)
        if next == 0x75 && pos + 5 < len, let hex = parseHex4(nsText, at: pos + 2) {
            return (hex, 6, true)
        }
        switch next {
        case 0x74: return (0x09, 2, true)
        case 0x6E: return (0x0A, 2, true)
        case 0x72: return (0x0D, 2, true)
        case 0x62: return (0x08, 2, true)
        case 0x66: return (0x0C, 2, true)
        case 0x22, 0x5C, 0x2F: return (next, 2, true)
        default: return (next, 2, false)
        }
    }

    private static func parseHex4(_ nsText: NSString, at pos: Int) -> unichar? {
        var value: UInt32 = 0
        for offset in 0..<4 {
            let ch = nsText.character(at: pos + offset)
            let digit: UInt32
            if ch >= 0x30 && ch <= 0x39 {
                digit = UInt32(ch - 0x30)
            } else if ch >= 0x61 && ch <= 0x66 {
                digit = UInt32(ch - 0x61 + 10)
            } else if ch >= 0x41 && ch <= 0x46 {
                digit = UInt32(ch - 0x41 + 10)
            } else {
                return nil
            }
            value = (value << 4) | digit
        }
        return unichar(value)
    }

    private static func redactAuthHeaderValue(
        _ nsText: NSString, valStart: Int, ctx: AuthValueContext, state: inout AuthScanState
    ) -> Int {
        let ch = nsText.character(at: valStart)
        if ch == 0x22 || ch == 0x27 {
            let afterQuote = redactQuotedAuthString(nsText, quotePos: valStart, quote: ch, state: &state)
            let validJsonStr =
                ctx.isJsonMember && ch == 0x22
                && scanJsonStringEnd(nsText, from: valStart + 1, len: nsText.length) == afterQuote
            return redactTrailingPlainAuthContinuation(
                nsText, afterPos: afterQuote, isJsonMember: validJsonStr, failedTopEnd: ctx.failedTopEnd, state: &state
            )
        }
        if ch == 0x5B {
            let afterArray = redactAuthArrayValue(nsText, start: valStart + 1, ctx: ctx, state: &state)
            let validJsonArr = ctx.isJsonMember && tryParseJsonValue(nsText, from: valStart, state: &state) == afterArray
            return redactTrailingPlainAuthContinuation(
                nsText, afterPos: afterArray, isJsonMember: validJsonArr, failedTopEnd: ctx.failedTopEnd, state: &state
            )
        }
        if ch == 0x7B,
            let next = redactJsonObject(
                nsText, from: valStart, isJsonMember: ctx.isJsonMember,
                allowTruncatedObj: ctx.allowTruncatedObj, state: &state
            )
        {
            return next < nsText.length
                ? redactTrailingPlainAuthContinuation(
                    nsText, afterPos: next, isJsonMember: ctx.isJsonMember, failedTopEnd: ctx.failedTopEnd, state: &state
                ) : next
        }
        if ctx.isJsonMember, let afterPrim = tryRedactJsonPrimitiveAuthValue(nsText, from: valStart, state: &state) {
            return afterPrim
        }
        return redactPlainAuthSpan(nsText, from: valStart, minEnd: ctx.failedTopEnd, state: &state)
    }

    private static func tryRedactJsonPrimitiveAuthValue(
        _ nsText: NSString, from valStart: Int, state: inout AuthScanState
    ) -> Int? {
        let len = nsText.length
        var tokenEnd = valStart
        while tokenEnd < len && !isJsonPrimitiveStop(nsText.character(at: tokenEnd)) { tokenEnd += 1 }
        guard tokenEnd > valStart else { return nil }
        let token = nsText.substring(with: NSRange(location: valStart, length: tokenEnd - valStart))
        let isNull = token == "null"
        guard isNull || token == "true" || token == "false" || isJsonNumber(token) else { return nil }
        let next = skipAuthWhitespace(nsText, from: tokenEnd, len: len, allowNewlines: true)
        guard next >= len || isJsonMemberContinuationDelimiter(nsText, at: next, allowTrailingProse: state.allowTrailingProse)
        else { return nil }
        if !isNull {
            state.appendRedacted(nsText, start: valStart, end: tokenEnd, replacement: "\"[redacted]\"")
        }
        return tokenEnd
    }

    private static func redactPlainAuthSpan(
        _ nsText: NSString, from valStart: Int, minEnd: Int, state: inout AuthScanState
    ) -> Int {
        var lineEnd = scanPlainAuthValueEnd(nsText, from: valStart, len: nsText.length)
        if minEnd > lineEnd { lineEnd = scanPlainAuthValueEnd(nsText, from: minEnd, len: nsText.length) }
        if let redacted = redactAuthValueBody(nsText, start: valStart, end: lineEnd) {
            state.appendRedacted(nsText, start: valStart, end: lineEnd, replacement: redacted)
        }
        return lineEnd
    }

    private static func redactTrailingPlainAuthContinuation(
        _ nsText: NSString, afterPos: Int, isJsonMember: Bool, failedTopEnd: Int, state: inout AuthScanState
    ) -> Int {
        let tailStart = findTrailingPlainAuthStart(
            nsText, afterPos: afterPos, isJsonMember: isJsonMember, allowTrailingProse: state.allowTrailingProse
        )
        if tailStart >= 0 {
            return redactPlainAuthSpan(nsText, from: tailStart, minEnd: failedTopEnd, state: &state)
        }
        if !isJsonMember && failedTopEnd > afterPos {
            let nextStart = skipJsonWhitespaceForward(nsText, from: afterPos, len: nsText.length)
            if nextStart < nsText.length {
                return redactPlainAuthSpan(nsText, from: nextStart, minEnd: failedTopEnd, state: &state)
            }
        }
        return afterPos
    }

    private static func findTrailingPlainAuthStart(
        _ nsText: NSString, afterPos: Int, isJsonMember: Bool, allowTrailingProse: Bool
    ) -> Int {
        let len = nsText.length
        var pos = afterPos
        while pos < len {
            while pos < len && isHorizSpace(nsText.character(at: pos)) { pos += 1 }
            let fold = advanceObsFold(nsText, at: pos, len: len)
            if fold > pos {
                pos = fold
                continue
            }
            break
        }
        guard pos < len && !isNewline(nsText.character(at: pos)) else { return -1 }
        if isJsonMember && isJsonMemberContinuationDelimiter(nsText, at: pos, allowTrailingProse: allowTrailingProse) {
            return -1
        }
        return pos
    }

    private static func scanPlainAuthValueEnd(_ nsText: NSString, from start: Int, len: Int) -> Int {
        var end = start
        while end < len {
            let ch = nsText.character(at: end)
            if isNewline(ch) {
                let fold = advanceObsFold(nsText, at: end, len: len)
                if fold > end {
                    end = fold
                    continue
                }
                break
            }
            end += 1
        }
        return end
    }

    private static func redactAuthArrayValue(
        _ nsText: NSString, start: Int, ctx: AuthValueContext, state: inout AuthScanState
    ) -> Int {
        let len = nsText.length
        var depth = 1
        var idx = start
        while idx < len && depth > 0 {
            let ch = nsText.character(at: idx)
            if ch == 0x5B {
                depth += 1
                idx += 1
            } else if ch == 0x5D {
                depth -= 1
                idx += 1
            } else if ch == 0x22 || ch == 0x27 {
                idx = redactQuotedAuthString(nsText, quotePos: idx, quote: ch, state: &state)
            } else if ch == 0x7B,
                let next = redactJsonObject(
                    nsText, from: idx, isJsonMember: ctx.isJsonMember,
                    allowTruncatedObj: ctx.allowTruncatedObj, state: &state
                )
            {
                idx = next
            } else if isHorizSpace(ch) || ch == 0x2C {
                idx += 1
            } else if isNewline(ch) {
                let next = nextAfterArrayNewline(
                    nsText, at: idx, len: len, allowNewlines: ctx.isJsonMember || ctx.allowTruncatedObj
                )
                if next < 0 { return idx }
                idx = next
            } else {
                idx = redactUnquotedArrayElement(nsText, from: idx, isJsonMember: ctx.isJsonMember, state: &state)
            }
        }
        return idx
    }

    private static func nextAfterArrayNewline(_ nsText: NSString, at pos: Int, len: Int, allowNewlines: Bool) -> Int {
        if allowNewlines { return pos + 1 }
        return advanceObsFold(nsText, at: pos, len: len)
    }
}

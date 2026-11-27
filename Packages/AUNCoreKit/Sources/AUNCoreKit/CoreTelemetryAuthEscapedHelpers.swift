import Foundation

extension CoreTelemetryAuthScanner {
    static func matchCanonicalAuthHeaderName(_ decoded: [unichar]) -> String? {
        var lo = 0
        var hi = decoded.count
        while lo < hi && (decoded[lo] == 0x20 || decoded[lo] == 0x09) { lo += 1 }
        while hi > lo && (decoded[hi - 1] == 0x20 || decoded[hi - 1] == 0x09) { hi -= 1 }
        guard lo < hi else { return nil }
        let slice = Array(decoded[lo..<hi])
        let key = String(utf16CodeUnits: slice, count: slice.count).lowercased()
        switch key {
        case "authorization": return "Authorization"
        case "proxy-authorization": return "Proxy-Authorization"
        case "cookie": return "Cookie"
        case "set-cookie": return "Set-Cookie"
        default: return nil
        }
    }

    static func resolveJsonTupleValueStart(
        _ nsText: NSString, afterComma: Int, len: Int, state: inout AuthScanState
    ) -> Int? {
        let valStart = skipAuthWhitespace(nsText, from: afterComma, len: len, allowNewlines: true)
        guard valStart < len else { return nil }
        let valEnd = tryParseJsonValue(nsText, from: valStart, state: &state)
        guard valEnd > valStart else { return nil }
        let afterVal = skipAuthWhitespace(nsText, from: valEnd, len: len, allowNewlines: true)
        return afterVal < len && nsText.character(at: afterVal) == 0x5D ? valStart : nil
    }

    static func tryRedactEscapedQuotedAuthHeader(
        _ nsText: NSString, at pos: Int, len: Int, state: inout AuthScanState
    ) -> Int? {
        guard let keyEnd = matchEscapedQuotedAuthKeyEnd(nsText, at: pos, len: len) else { return nil }
        let sep = skipAuthWhitespace(nsText, from: keyEnd, len: len, allowNewlines: false)
        guard let (sepLen, isTuple) = matchEscapedAuthSeparator(nsText, keyStart: pos, sep: sep, len: len) else {
            return nil
        }
        let valStart = skipAuthWhitespace(nsText, from: sep + sepLen, len: len, allowNewlines: false)
        guard valStart < len && !isNewline(nsText.character(at: valStart)) else { return nil }
        return redactEscapedAuthHeaderValue(nsText, valStart: valStart, len: len, isTuple: isTuple, state: &state)
    }

    private static func matchEscapedQuotedAuthKeyEnd(_ nsText: NSString, at pos: Int, len: Int) -> Int? {
        let limit = min(len, pos + 256)
        var decoded: [unichar] = []
        decoded.reserveCapacity(64)
        var idx = pos + 2
        while idx < limit {
            let ch = nsText.character(at: idx)
            if ch < 0x20 || ch == 0x22 { return nil }
            if ch == 0x5C && idx + 1 < limit {
                let next = nsText.character(at: idx + 1)
                if next == 0x22 {
                    return matchCanonicalAuthHeaderName(decoded) != nil ? idx + 2 : nil
                }
                guard decoded.count < 64 else { return nil }
                if next == 0x75 && idx + 5 < limit, let code = CoreTelemetryService.parseHex4(nsText, pos: idx + 2) {
                    decoded.append(code)
                    idx += 6
                } else {
                    decoded.append(decodeSimpleJsonEscape(next))
                    idx += 2
                }
                continue
            }
            guard decoded.count < 64 else { return nil }
            decoded.append(ch)
            idx += 1
        }
        return nil
    }

    private static func decodeSimpleJsonEscape(_ next: unichar) -> unichar {
        switch next {
        case 0x74: return 0x09
        case 0x6E: return 0x0A
        case 0x72: return 0x0D
        case 0x62: return 0x08
        case 0x66: return 0x0C
        default: return next
        }
    }

    private static func matchEscapedAuthSeparator(
        _ nsText: NSString, keyStart: Int, sep: Int, len: Int
    ) -> (Int, Bool)? {
        if let (sepLen, _) = matchAuthSeparator(nsText, at: sep, len: len) { return (sepLen, false) }
        let prevDelim = skipJsonWhitespaceBackward(nsText, from: keyStart - 1)
        if prevDelim >= 0 && nsText.character(at: prevDelim) == 0x5B && sep < len && nsText.character(at: sep) == 0x2C {
            return (1, true)
        }
        return nil
    }

    private static func redactEscapedAuthHeaderValue(
        _ nsText: NSString, valStart: Int, len: Int, isTuple: Bool, state: inout AuthScanState
    ) -> Int? {
        if valStart + 1 < len && nsText.character(at: valStart) == 0x5C && nsText.character(at: valStart + 1) == 0x22 {
            return redactEscapedStringAuthValue(nsText, valStart: valStart, len: len, isTuple: isTuple, state: &state)
        }
        let ch = nsText.character(at: valStart)
        if !isTuple && ch == 0x5B {
            return redactEscapedAuthArrayValue(nsText, from: valStart + 1, len: len, state: &state)
        }
        if !isTuple && ch == 0x7B, let objEnd = scanEscapedJsonObjectEnd(nsText, from: valStart, len: len) {
            state.appendRedacted(nsText, start: valStart, end: objEnd, replacement: "\\\"[redacted]\\\"")
            return objEnd
        }
        if let primEnd = tryRedactEscapedJsonPrimitive(nsText, valStart: valStart, len: len, isTuple: isTuple, state: &state) {
            return primEnd
        }
        if !isTuple {
            return redactPlainAuthSpanFromEscaped(nsText, from: valStart, len: len, state: &state)
        }
        return nil
    }

    private static func redactEscapedStringAuthValue(
        _ nsText: NSString, valStart: Int, len: Int, isTuple: Bool, state: inout AuthScanState
    ) -> Int? {
        let closeVal = scanEscapedQuotedAuthValueEnd(nsText, from: valStart + 2, len: len)
        let hasClose =
            closeVal + 1 < len && nsText.character(at: closeVal) == 0x5C
            && nsText.character(at: closeVal + 1) == 0x22
        let afterClose = hasClose ? closeVal + 2 : closeVal
        if isTuple {
            let afterVal = skipAuthWhitespace(nsText, from: afterClose, len: len, allowNewlines: false)
            guard afterVal < len && nsText.character(at: afterVal) == 0x5D else { return nil }
        }
        if let redacted = redactAuthValueBody(nsText, start: valStart + 2, end: closeVal) {
            state.appendRedacted(nsText, start: valStart + 2, end: closeVal, replacement: redacted)
        }
        return afterClose
    }

    private static func tryRedactEscapedJsonPrimitive(
        _ nsText: NSString, valStart: Int, len: Int, isTuple: Bool, state: inout AuthScanState
    ) -> Int? {
        var tokEnd = valStart
        while tokEnd < len && !isEscapedScalarStop(nsText.character(at: tokEnd)) { tokEnd += 1 }
        guard tokEnd > valStart else { return nil }
        let token = nsText.substring(with: NSRange(location: valStart, length: tokEnd - valStart))
        let isNull = token == "null"
        guard isNull || token == "true" || token == "false" || isJsonNumber(token) else { return nil }
        let after = skipAuthWhitespace(nsText, from: tokEnd, len: len, allowNewlines: false)
        if isTuple {
            guard after < len && nsText.character(at: after) == 0x5D else { return nil }
        } else if after < len {
            let aCh = nsText.character(at: after)
            guard aCh == 0x2C || aCh == 0x7D || aCh == 0x5D || isNewline(aCh) else { return nil }
        }
        if !isNull {
            state.appendRedacted(nsText, start: valStart, end: tokEnd, replacement: "\\\"[redacted]\\\"")
        }
        return tokEnd
    }

    private static func isEscapedScalarStop(_ ch: unichar) -> Bool {
        isHorizSpace(ch) || isNewline(ch) || ch == 0x2C || ch == 0x7D || ch == 0x5D || ch == 0x22
    }

    private static func scanEscapedJsonObjectEnd(_ nsText: NSString, from start: Int, len: Int) -> Int? {
        var pos = start
        var depth = 0
        while pos < len {
            let ch = nsText.character(at: pos)
            if isNewline(ch) || ch == 0x22 { return nil }
            if ch == 0x5C && pos + 1 < len && nsText.character(at: pos + 1) == 0x22 {
                let closeVal = scanEscapedQuotedAuthValueEnd(nsText, from: pos + 2, len: len)
                guard
                    closeVal + 1 < len && nsText.character(at: closeVal) == 0x5C
                        && nsText.character(at: closeVal + 1) == 0x22
                else { return nil }
                pos = closeVal + 2
                continue
            }
            if ch == 0x7B { depth += 1 }
            if ch == 0x7D {
                depth -= 1
                if depth == 0 { return pos + 1 }
            }
            pos += 1
        }
        return nil
    }

    private static func scanEscapedQuotedAuthValueEnd(_ nsText: NSString, from start: Int, len: Int) -> Int {
        var pos = start
        var innerEscaped = false
        while pos < len {
            let ch = nsText.character(at: pos)
            if ch == 0x0A || ch == 0x0D || ch == 0x22 { return pos }
            if ch == 0x5C && pos + 1 < len {
                let next = nsText.character(at: pos + 1)
                if next == 0x22 && !innerEscaped { return pos }
                innerEscaped = next == 0x5C ? !innerEscaped : false
                pos += 2
                continue
            }
            innerEscaped = false
            pos += 1
        }
        return pos
    }

    private static func redactEscapedAuthArrayValue(
        _ nsText: NSString, from start: Int, len: Int, state: inout AuthScanState
    ) -> Int {
        var pos = start
        var depth = 1
        while pos < len && depth > 0 {
            let ch = nsText.character(at: pos)
            if ch == 0x0A || ch == 0x0D || ch == 0x22 { return pos }
            if isHorizSpace(ch) || ch == 0x2C {
                pos += 1
            } else if ch == 0x5B {
                depth += 1
                pos += 1
            } else if ch == 0x5D {
                depth -= 1
                pos += 1
            } else {
                pos = redactEscapedArrayElement(nsText, from: pos, len: len, state: &state)
            }
        }
        return pos
    }

    private static func redactEscapedArrayElement(
        _ nsText: NSString, from pos: Int, len: Int, state: inout AuthScanState
    ) -> Int {
        let ch = nsText.character(at: pos)
        if ch == 0x5C && pos + 1 < len && nsText.character(at: pos + 1) == 0x22 {
            let closeVal = scanEscapedQuotedAuthValueEnd(nsText, from: pos + 2, len: len)
            if let redacted = redactAuthValueBody(nsText, start: pos + 2, end: closeVal) {
                state.appendRedacted(nsText, start: pos + 2, end: closeVal, replacement: redacted)
            }
            let hasClose =
                closeVal + 1 < len && nsText.character(at: closeVal) == 0x5C
                && nsText.character(at: closeVal + 1) == 0x22
            return hasClose ? closeVal + 2 : closeVal
        }
        if ch == 0x7B, let objEnd = scanEscapedJsonObjectEnd(nsText, from: pos, len: len) {
            state.appendRedacted(nsText, start: pos, end: objEnd, replacement: "\\\"[redacted]\\\"")
            return objEnd
        }
        var elemEnd = pos
        while elemEnd < len && !isEscapedScalarStop(nsText.character(at: elemEnd))
            && nsText.character(at: elemEnd) != 0x5B
        {
            elemEnd += 1
        }
        if elemEnd > pos {
            let token = nsText.substring(with: NSRange(location: pos, length: elemEnd - pos))
            if token != "null" {
                state.appendRedacted(nsText, start: pos, end: elemEnd, replacement: "\\\"[redacted]\\\"")
            }
            return elemEnd
        }
        return pos + 1
    }

    private static func redactPlainAuthSpanFromEscaped(
        _ nsText: NSString, from valStart: Int, len: Int, state: inout AuthScanState
    ) -> Int {
        var end = valStart
        while end < len && !isNewline(nsText.character(at: end)) { end += 1 }
        if let redacted = redactAuthValueBody(nsText, start: valStart, end: end) {
            state.appendRedacted(nsText, start: valStart, end: end, replacement: redacted)
        }
        return end
    }
}

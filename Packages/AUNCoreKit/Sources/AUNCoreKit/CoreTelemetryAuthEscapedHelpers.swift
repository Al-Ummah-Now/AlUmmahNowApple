import Foundation

extension CoreTelemetryAuthScanner {
    static func matchCanonicalAuthHeaderName(_ decoded: [unichar]) -> String? {
        var lo = 0
        var hi = decoded.count
        while lo < hi && (decoded[lo] == 0x20 || decoded[lo] == 0x09) { lo += 1 }
        while hi > lo && (decoded[hi - 1] == 0x20 || decoded[hi - 1] == 0x09) { hi -= 1 }
        guard lo < hi else { return nil }
        let slice = Array(decoded[lo..<hi])
        let preserved = String(utf16CodeUnits: slice, count: slice.count)
        let key = preserved.lowercased()
        switch key {
        case "authorization", "proxy-authorization", "cookie", "set-cookie": return preserved
        default: return nil
        }
    }

    static func appendTrimmedKeyUnit(
        _ unit: unichar, core: inout [unichar], padState: inout (trailing: Bool, any: Bool)
    ) -> Bool {
        if unit == 0x20 || unit == 0x09 {
            padState.any = true
            if !core.isEmpty { padState.trailing = true }
            return true
        }
        if padState.trailing || core.count >= 19 { return false }
        core.append(unit)
        return true
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
        let prevDelim = skipEscapedWhitespaceBackward(nsText, from: pos - 1)
        let prevCh = prevDelim >= 0 ? nsText.character(at: prevDelim) : 0
        let isEscapedJsonCtx = prevCh == 0x7B || prevCh == 0x2C || prevCh == 0x5B
        let sep = skipEscapedAuthWhitespace(nsText, from: keyEnd, len: len, allowNewlines: isEscapedJsonCtx)
        guard let (sepLen, isTuple) = matchEscapedAuthSeparator(nsText, prevCh: prevCh, sep: sep, len: len) else {
            return nil
        }
        let valStart = skipEscapedAuthWhitespace(nsText, from: sep + sepLen, len: len, allowNewlines: isEscapedJsonCtx)
        guard valStart < len && !isNewline(nsText.character(at: valStart)) else { return nil }
        return redactEscapedAuthHeaderValue(nsText, valStart: valStart, len: len, isTuple: isTuple, state: &state)
    }

    private static func isEscapedWhitespaceToken(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        guard pos + 1 < len && nsText.character(at: pos) == 0x5C else { return false }
        let next = nsText.character(at: pos + 1)
        return next == 0x74 || next == 0x6E || next == 0x72
    }

    private static func skipEscapedAuthWhitespace(
        _ nsText: NSString, from start: Int, len: Int, allowNewlines: Bool
    ) -> Int {
        var pos = start
        while pos < len {
            let ch = nsText.character(at: pos)
            if isHorizSpace(ch) || (allowNewlines && isNewline(ch)) {
                pos += 1
            } else if ch == 0x5C && pos + 1 < len {
                let next = nsText.character(at: pos + 1)
                if next == 0x74 || (allowNewlines && (next == 0x6E || next == 0x72)) {
                    pos += 2
                } else {
                    break
                }
            } else {
                break
            }
        }
        return pos
    }

    private static func skipEscapedWhitespaceBackward(_ nsText: NSString, from start: Int) -> Int {
        var pos = start
        while pos >= 0 {
            let ch = nsText.character(at: pos)
            if isHorizSpace(ch) || isNewline(ch) {
                pos -= 1
            } else if pos >= 1 && nsText.character(at: pos - 1) == 0x5C
                && (ch == 0x74 || ch == 0x6E || ch == 0x72)
                && !CoreTelemetryService.VaultLineTracker.isPrecededByOddBackslashes(nsText, at: pos - 1, minPos: 0)
            {
                pos -= 2
            } else {
                break
            }
        }
        return pos
    }

    private static func matchEscapedQuotedAuthKeyEnd(_ nsText: NSString, at pos: Int, len: Int) -> Int? {
        var core: [unichar] = []
        core.reserveCapacity(20)
        var padState = (trailing: false, any: false)
        var idx = pos + 2
        while idx < len {
            let ch = nsText.character(at: idx)
            if (ch < 0x20 && ch != 0x09) || ch == 0x22 { return nil }
            if ch == 0x5C && idx + 1 < len {
                let next = nsText.character(at: idx + 1)
                if next == 0x22 { return matchCanonicalAuthHeaderName(core) != nil ? idx + 2 : nil }
                let (unit, step) = decodeEscapedKeyUnit(nsText, at: idx, len: len)
                guard appendTrimmedKeyUnit(unit, core: &core, padState: &padState) else { return nil }
                idx += step
            } else {
                guard appendTrimmedKeyUnit(ch, core: &core, padState: &padState) else { return nil }
                idx += 1
            }
        }
        return nil
    }

    private static func decodeEscapedKeyUnit(_ nsText: NSString, at pos: Int, len: Int) -> (unichar, Int) {
        let next = nsText.character(at: pos + 1)
        if next == 0x75 && pos + 5 < len, let code = CoreTelemetryService.parseHex4(nsText, pos: pos + 2) {
            return (code, 6)
        }
        return (decodeSimpleJsonEscape(next), 2)
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
        _ nsText: NSString, prevCh: unichar, sep: Int, len: Int
    ) -> (Int, Bool)? {
        if let (sepLen, _) = matchAuthSeparator(nsText, at: sep, len: len) { return (sepLen, false) }
        if prevCh == 0x5B && sep < len && nsText.character(at: sep) == 0x2C { return (1, true) }
        return nil
    }

    private static func redactEscapedAuthHeaderValue(
        _ nsText: NSString, valStart: Int, len: Int, isTuple: Bool, state: inout AuthScanState
    ) -> Int? {
        if valStart + 1 < len && nsText.character(at: valStart) == 0x5C && nsText.character(at: valStart + 1) == 0x22 {
            return redactEscapedStringAuthValue(nsText, valStart: valStart, len: len, isTuple: isTuple, state: &state)
        }
        let ch = nsText.character(at: valStart)
        if ch == 0x5B {
            if isTuple {
                guard let arrEnd = scanEscapedJsonContainerEnd(nsText, from: valStart, len: len, state: &state),
                    isTupleClosedAt(nsText, afterPos: arrEnd, len: len)
                else { return nil }
            }
            return redactEscapedAuthArrayValue(nsText, from: valStart + 1, len: len, state: &state)
        }
        if ch == 0x7B, let objEnd = scanEscapedJsonContainerEnd(nsText, from: valStart, len: len, state: &state) {
            if isTuple && !isTupleClosedAt(nsText, afterPos: objEnd, len: len) { return nil }
            state.appendRedacted(nsText, start: valStart, end: objEnd, replacement: "\\\"[redacted]\\\"")
            return objEnd
        }
        if let primEnd = tryRedactEscapedJsonPrimitive(nsText, valStart: valStart, len: len, isTuple: isTuple, state: &state) {
            return primEnd
        }
        return !isTuple ? redactPlainAuthSpanFromEscaped(nsText, from: valStart, len: len, state: &state) : nil
    }

    private static func isTupleClosedAt(_ nsText: NSString, afterPos: Int, len: Int) -> Bool {
        let after = skipEscapedAuthWhitespace(nsText, from: afterPos, len: len, allowNewlines: true)
        return after < len && nsText.character(at: after) == 0x5D
    }

    private static func redactEscapedStringAuthValue(
        _ nsText: NSString, valStart: Int, len: Int, isTuple: Bool, state: inout AuthScanState
    ) -> Int? {
        let closeVal = scanEscapedQuotedAuthValueEnd(nsText, from: valStart + 2, len: len)
        let hasClose =
            closeVal + 1 < len && nsText.character(at: closeVal) == 0x5C
            && nsText.character(at: closeVal + 1) == 0x22
        let afterClose = hasClose ? closeVal + 2 : closeVal
        if isTuple && !isTupleClosedAt(nsText, afterPos: afterClose, len: len) { return nil }
        if let redacted = redactAuthValueBody(nsText, start: valStart + 2, end: closeVal) {
            state.appendRedacted(nsText, start: valStart + 2, end: closeVal, replacement: redacted)
        }
        return afterClose
    }

    private static func tryRedactEscapedJsonPrimitive(
        _ nsText: NSString, valStart: Int, len: Int, isTuple: Bool, state: inout AuthScanState
    ) -> Int? {
        var tokEnd = valStart
        while tokEnd < len && !isEscapedScalarStop(nsText.character(at: tokEnd))
            && !isEscapedWhitespaceToken(nsText, at: tokEnd, len: len)
        {
            tokEnd += 1
        }
        guard tokEnd > valStart else { return nil }
        let token = nsText.substring(with: NSRange(location: valStart, length: tokEnd - valStart))
        let isNull = token == "null"
        guard isNull || token == "true" || token == "false" || isJsonNumber(token) else { return nil }
        guard isValidEscapedPrimitiveEnd(nsText, tokEnd: tokEnd, len: len, isTuple: isTuple) else { return nil }
        if !isNull {
            state.appendRedacted(nsText, start: valStart, end: tokEnd, replacement: "\\\"[redacted]\\\"")
        }
        return tokEnd
    }

    private static func isValidEscapedPrimitiveEnd(_ nsText: NSString, tokEnd: Int, len: Int, isTuple: Bool) -> Bool {
        if isTuple { return isTupleClosedAt(nsText, afterPos: tokEnd, len: len) }
        let after = skipEscapedAuthWhitespace(nsText, from: tokEnd, len: len, allowNewlines: true)
        guard after < len else { return true }
        let aCh = nsText.character(at: after)
        return aCh == 0x2C || aCh == 0x7D || aCh == 0x5D || isNewline(aCh)
    }

    private static func isEscapedScalarStop(_ ch: unichar) -> Bool {
        isHorizSpace(ch) || isNewline(ch) || ch == 0x2C || ch == 0x7D || ch == 0x5D || ch == 0x22
    }

    private static func scanEscapedJsonContainerEnd(
        _ nsText: NSString, from start: Int, len: Int, state: inout AuthScanState
    ) -> Int? {
        if let cached = state.escapedContainerEnd[start] { return cached > start ? cached : nil }
        var stack: [(openPos: Int, expectedClose: unichar)] = []
        var pos = start
        while pos < len {
            let next = stepEscapedContainer(nsText, at: pos, len: len, stack: &stack, state: &state)
            if next == Int.min { break }
            if next >= 0 && stack.isEmpty { return next }
            pos = next < 0 ? (-next - 2) : next
        }
        for item in stack { state.escapedContainerEnd[item.openPos] = -1 }
        state.escapedContainerEnd[start] = -1
        return nil
    }

    private static func stepEscapedContainer(
        _ nsText: NSString,
        at pos: Int,
        len: Int,
        stack: inout [(openPos: Int, expectedClose: unichar)],
        state: inout AuthScanState
    ) -> Int {
        let ch = nsText.character(at: pos)
        if ch == 0x22 { return Int.min }
        if ch == 0x5C && pos + 1 < len && nsText.character(at: pos + 1) == 0x22 {
            let closeVal = scanEscapedQuotedAuthValueEnd(nsText, from: pos + 2, len: len)
            guard
                closeVal + 1 < len && nsText.character(at: closeVal) == 0x5C
                    && nsText.character(at: closeVal + 1) == 0x22
            else { return Int.min }
            return -((closeVal + 2) + 2)
        }
        if ch == 0x7B || ch == 0x5B {
            if let known = state.escapedContainerEnd[pos] { return known > pos ? known : Int.min }
            stack.append((pos, ch == 0x7B ? 0x7D : 0x5D))
            return -((pos + 1) + 2)
        }
        if ch == 0x7D || ch == 0x5D {
            guard let top = stack.popLast(), top.expectedClose == ch else { return Int.min }
            state.escapedContainerEnd[top.openPos] = pos + 1
            return pos + 1
        }
        return -((pos + 1) + 2)
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
            if ch == 0x22 { return pos }
            if isHorizSpace(ch) || isNewline(ch) || ch == 0x2C {
                pos += 1
            } else if isEscapedWhitespaceToken(nsText, at: pos, len: len) {
                pos += 2
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
        if ch == 0x7B, let objEnd = scanEscapedJsonContainerEnd(nsText, from: pos, len: len, state: &state) {
            state.appendRedacted(nsText, start: pos, end: objEnd, replacement: "\\\"[redacted]\\\"")
            return objEnd
        }
        var elemEnd = pos
        while elemEnd < len && !isEscapedScalarStop(nsText.character(at: elemEnd))
            && nsText.character(at: elemEnd) != 0x5B
            && !isEscapedWhitespaceToken(nsText, at: elemEnd, len: len)
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

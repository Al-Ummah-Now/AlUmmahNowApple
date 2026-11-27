import Foundation

extension CoreTelemetryAuthScanner {
    static func redactBasicTokens(in text: String) -> String {
        guard let regex = basicTokenRegex else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var copied = 0
        for match in matches {
            let token = nsText.substring(with: match.range(at: 2))
            guard isBasicCredentialToken(token) else { continue }
            if result.isEmpty { result.reserveCapacity(text.count) }
            result += nsText.substring(with: NSRange(location: copied, length: match.range.location - copied))
            result += nsText.substring(with: match.range(at: 1))
            result += " [redacted]"
            copied = match.range.location + match.range.length
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    private static func isBasicCredentialToken(_ token: String) -> Bool {
        guard let data = decodeCanonicalBase64(token), data.contains(0x3A) else { return false }
        if let decoded = String(data: data, encoding: .utf8) {
            let hasControl = decoded.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7F || ($0.value >= 0x80 && $0.value <= 0x9F)
            }
            if !hasControl { return true }
        }
        return !data.contains { $0 < 0x20 || ($0 >= 0x7F && $0 <= 0x9F) }
    }

    private static func decodeCanonicalBase64(_ token: String) -> Data? {
        let bytes = Array(token.utf8)
        var unpaddedLen = bytes.count
        while unpaddedLen > 0 && bytes[unpaddedLen - 1] == 0x3D { unpaddedLen -= 1 }
        let pad = bytes.count - unpaddedLen
        guard pad <= 2, pad == 0 || (bytes.count & 3) == 0 else { return nil }
        let rem = unpaddedLen & 3
        guard rem != 1, pad == 0 || rem + pad == 4 else { return nil }
        if rem == 2 && (base64ByteValue(bytes[unpaddedLen - 1]) & 0x0F) != 0 { return nil }
        if rem == 3 && (base64ByteValue(bytes[unpaddedLen - 1]) & 0x03) != 0 { return nil }
        guard let rawNormalized = String(bytes: bytes[0..<unpaddedLen], encoding: .utf8) else { return nil }
        var normalized =
            rawNormalized
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if rem == 2 { normalized += "==" } else if rem == 3 { normalized += "=" }
        return Data(base64Encoded: normalized)
    }

    private static func base64ByteValue(_ byte: UInt8) -> Int {
        if byte >= 0x41 && byte <= 0x5A { return Int(byte - 0x41) }
        if byte >= 0x61 && byte <= 0x7A { return Int(byte - 0x61 + 26) }
        if byte >= 0x30 && byte <= 0x39 { return Int(byte - 0x30 + 52) }
        if byte == 0x2B || byte == 0x2D { return 62 }
        if byte == 0x2F || byte == 0x5F { return 63 }
        return -1
    }

    static func skipAuthWhitespace(_ nsText: NSString, from pos: Int, len: Int, allowNewlines: Bool) -> Int {
        var idx = pos
        while idx < len {
            let ch = nsText.character(at: idx)
            if isHorizSpace(ch) || (allowNewlines && isNewline(ch)) {
                idx += 1
            } else if !allowNewlines && isNewline(ch) {
                let fold = advanceObsFold(nsText, at: idx, len: len)
                if fold > idx { idx = fold } else { break }
            } else {
                break
            }
        }
        return idx
    }

    static func advanceObsFold(_ nsText: NSString, at nlPos: Int, len: Int) -> Int {
        guard nlPos < len && isNewline(nsText.character(at: nlPos)) else { return -1 }
        let afterNl =
            (nsText.character(at: nlPos) == 0x0D && nlPos + 1 < len && nsText.character(at: nlPos + 1) == 0x0A)
            ? nlPos + 2 : nlPos + 1
        guard afterNl < len && isHorizSpace(nsText.character(at: afterNl)) else { return -1 }
        var idx = afterNl
        while idx < len && isHorizSpace(nsText.character(at: idx)) { idx += 1 }
        return idx
    }

    static func isHorizSpace(_ ch: unichar) -> Bool { ch == 0x20 || ch == 0x09 }
    static func isNewline(_ ch: unichar) -> Bool { ch == 0x0A || ch == 0x0D }
    static func isJsonDelimiter(_ ch: unichar) -> Bool { ch == 0x2C || ch == 0x7D || ch == 0x5D }

    static func isPrecededByBraceOrComma(_ nsText: NSString, before pos: Int) -> Bool {
        let idx = skipJsonWhitespaceBackward(nsText, from: pos - 1)
        guard idx >= 0 else { return false }
        let ch = nsText.character(at: idx)
        return ch == 0x7B || ch == 0x2C
    }

    static func findEnclosingJsonObjectStart(
        _ nsText: NSString, before pos: Int, state: inout AuthScanState
    ) -> Int {
        let idx = skipJsonWhitespaceBackward(nsText, from: pos - 1)
        guard idx >= 0 else { return -1 }
        if nsText.character(at: idx) == 0x7B { return idx }
        guard nsText.character(at: idx) == 0x2C else { return -1 }
        return findEnclosingJsonObjectStartFromComma(nsText, commaPos: idx, state: &state)
    }

    private static func findEnclosingJsonObjectStartFromComma(
        _ nsText: NSString, commaPos: Int, state: inout AuthScanState
    ) -> Int {
        if let cached = state.memberCommaOpen[commaPos] { return cached }
        var visited: [Int] = []
        var idx = commaPos
        var openBrace = -1
        while idx >= 0 && nsText.character(at: idx) == 0x2C {
            if let known = state.memberCommaOpen[idx] {
                openBrace = known
                break
            }
            visited.append(idx)
            let beforeKey = stepBackOverJsonMember(nsText, beforeComma: idx, state: &state)
            guard beforeKey >= 0 else { break }
            if nsText.character(at: beforeKey) == 0x7B {
                openBrace = beforeKey
                break
            }
            idx = beforeKey
        }
        for pos in visited { state.memberCommaOpen[pos] = openBrace }
        return openBrace
    }

    private static func findEnclosingJsonArrayStartFromComma(
        _ nsText: NSString, commaPos: Int, state: inout AuthScanState
    ) -> Int {
        if let cached = state.arrayCommaOpen[commaPos] { return cached }
        var visited: [Int] = []
        var idx = commaPos
        var openBracket = -1
        while idx >= 0 && nsText.character(at: idx) == 0x2C {
            if let known = state.arrayCommaOpen[idx] {
                openBracket = known
                break
            }
            visited.append(idx)
            let beforeVal = stepBackOverJsonArrayElement(nsText, beforeComma: idx, state: &state)
            guard beforeVal >= 0 else { break }
            if nsText.character(at: beforeVal) == 0x5B {
                openBracket = beforeVal
                break
            }
            idx = beforeVal
        }
        for pos in visited { state.arrayCommaOpen[pos] = openBracket }
        return openBracket
    }

    private static func stepBackOverJsonArrayElement(
        _ nsText: NSString, beforeComma commaPos: Int, state: inout AuthScanState
    ) -> Int {
        let prev = skipJsonWhitespaceBackward(nsText, from: commaPos - 1)
        guard prev >= 0 else { return -1 }
        let valStart = findJsonValueStartBackward(nsText, end: prev, state: &state)
        guard valStart > 0 else { return -1 }
        let beforeVal = skipJsonWhitespaceBackward(nsText, from: valStart - 1)
        guard beforeVal >= 0 else { return -1 }
        let ch = nsText.character(at: beforeVal)
        return (ch == 0x5B || ch == 0x2C) ? beforeVal : -1
    }

    static func classifyTopLevelJsonContainer(
        _ nsText: NSString, openPos: Int, state: inout AuthScanState
    ) -> Int {
        if let cached = state.containerAuthState[openPos] { return cached }
        var visited: [Int] = []
        var curOpen = openPos
        var authState = -1
        while curOpen >= 0 {
            if let known = state.containerAuthState[curOpen] {
                authState = known
                break
            }
            visited.append(curOpen)
            let endPos = tryParseJsonValue(nsText, from: curOpen, state: &state)
            guard endPos > curOpen else { break }
            let parentOpen = findParentJsonContainerOpen(nsText, before: curOpen, state: &state)
            if parentOpen >= 0 {
                curOpen = parentOpen
                continue
            }
            authState = reachesLineOrTextEnd(nsText, from: endPos) ? 0 : endPos
            break
        }
        for pos in visited { state.containerAuthState[pos] = authState }
        return authState
    }

    private static func reachesLineOrTextEnd(_ nsText: NSString, from start: Int) -> Bool {
        let len = nsText.length
        var idx = start
        while idx < len && isHorizSpace(nsText.character(at: idx)) { idx += 1 }
        return idx >= len || isNewline(nsText.character(at: idx))
    }

    private static func findParentJsonContainerOpen(
        _ nsText: NSString, before valueStart: Int, state: inout AuthScanState
    ) -> Int {
        let prev = skipJsonWhitespaceBackward(nsText, from: valueStart - 1)
        guard prev >= 0 else { return -1 }
        let ch = nsText.character(at: prev)
        if ch == 0x3A {
            let beforeKey = findDelimiterBeforeJsonMemberKeyColon(nsText, before: valueStart)
            guard beforeKey >= 0 else { return -1 }
            return nsText.character(at: beforeKey) == 0x7B
                ? beforeKey : findEnclosingJsonObjectStartFromComma(nsText, commaPos: beforeKey, state: &state)
        }
        if ch == 0x5B { return prev }
        if ch == 0x2C { return findEnclosingJsonArrayStartFromComma(nsText, commaPos: prev, state: &state) }
        return -1
    }

    private static func stepBackOverJsonMember(
        _ nsText: NSString, beforeComma commaPos: Int, state: inout AuthScanState
    ) -> Int {
        let prev = skipJsonWhitespaceBackward(nsText, from: commaPos - 1)
        guard prev >= 0 else { return -1 }
        let valueStart = findJsonValueStartBackward(nsText, end: prev, state: &state)
        guard valueStart > 0 else { return -1 }
        return findDelimiterBeforeJsonMemberKeyColon(nsText, before: valueStart)
    }

    private static func findJsonValueStartBackward(
        _ nsText: NSString, end prev: Int, state: inout AuthScanState
    ) -> Int {
        let ch = nsText.character(at: prev)
        if ch == 0x22 { return scanJsonStringStartBackward(nsText, from: prev) }
        if ch == 0x7D || ch == 0x5D {
            return scanContainerStartBackward(nsText, closePos: prev, state: &state)
        }
        if ch >= 0x30 && ch <= 0x39 {
            var start = prev
            while start >= 0 && !isJsonValuePrefixStop(nsText.character(at: start)) { start -= 1 }
            let token = nsText.substring(with: NSRange(location: start + 1, length: prev - start))
            return isJsonNumber(token) ? start + 1 : -1
        }
        return findJsonKeywordStartEndingAt(nsText, end: prev)
    }

    private static func findJsonKeywordStartEndingAt(_ nsText: NSString, end: Int) -> Int {
        for keyword in ["true", "false", "null"] {
            let kwLen = keyword.utf16.count
            let start = end - kwLen + 1
            if start > 0 && nsText.substring(with: NSRange(location: start, length: kwLen)) == keyword {
                return start
            }
        }
        return -1
    }

    private static func findDelimiterBeforeJsonMemberKeyColon(_ nsText: NSString, before pos: Int) -> Int {
        let colonPos = skipJsonWhitespaceBackward(nsText, from: pos - 1)
        guard colonPos > 0 && nsText.character(at: colonPos) == 0x3A else { return -1 }
        let keyEnd = skipJsonWhitespaceBackward(nsText, from: colonPos - 1)
        guard keyEnd > 0 && nsText.character(at: keyEnd) == 0x22 else { return -1 }
        let keyStart = scanJsonStringStartBackward(nsText, from: keyEnd)
        guard keyStart > 0 else { return -1 }
        let beforeKey = skipJsonWhitespaceBackward(nsText, from: keyStart - 1)
        guard beforeKey >= 0 else { return -1 }
        let ch = nsText.character(at: beforeKey)
        return (ch == 0x7B || ch == 0x2C) ? beforeKey : -1
    }

    private static func skipJsonWhitespaceBackward(_ nsText: NSString, from start: Int) -> Int {
        var idx = start
        while idx >= 0 && (isHorizSpace(nsText.character(at: idx)) || isNewline(nsText.character(at: idx))) { idx -= 1 }
        return idx
    }

    private static func isEscapedQuote(_ nsText: NSString, at quotePos: Int) -> Bool {
        var count = 0
        var idx = quotePos - 1
        while idx >= 0 && nsText.character(at: idx) == 0x5C {
            count += 1
            idx -= 1
        }
        return (count & 1) == 1
    }

    private static func scanJsonStringStartBackward(_ nsText: NSString, from closeQuotePos: Int) -> Int {
        var open = -1
        var idx = closeQuotePos - 1
        while idx >= 0 {
            let ch = nsText.character(at: idx)
            if ch < 0x20 { return -1 }
            if ch == 0x22 && !isEscapedQuote(nsText, at: idx) {
                open = idx
                break
            }
            idx -= 1
        }
        guard open >= 0 else { return -1 }
        return scanJsonStringEnd(nsText, from: open + 1, len: nsText.length) == closeQuotePos + 1 ? open : -1
    }

    private static func scanContainerStartBackward(
        _ nsText: NSString, closePos: Int, state: inout AuthScanState
    ) -> Int {
        if let cached = state.closeToOpenMap[closePos] { return cached }
        guard closePos > state.failedContainerBack else { return -1 }
        let matched = walkContainerBackward(nsText, closePos: closePos, state: &state)
        if matched < 0 {
            state.closeToOpenMap[closePos] = -1
            state.failedContainerBack = max(state.failedContainerBack, closePos)
        }
        return matched
    }

    private static func walkContainerBackward(
        _ nsText: NSString, closePos: Int, state: inout AuthScanState
    ) -> Int {
        var stack: [(closeIdx: Int, expectedOpen: unichar)] = []
        var idx = closePos
        while idx > state.failedContainerBack {
            let nextIdx = stepContainerBackward(nsText, at: idx, stack: &stack, state: &state)
            if nextIdx == Int.min { break }
            if nextIdx >= 0 && stack.isEmpty { return nextIdx }
            idx = nextIdx < 0 ? (-nextIdx - 2) : (nextIdx - 1)
        }
        for unmatched in stack { state.closeToOpenMap[unmatched.closeIdx] = -1 }
        return -1
    }

    /// Returns `Int.min` on failure, `>= 0` when an opener matched (the opener index),
    /// or `-(nextIdx + 2)` to continue scanning at `nextIdx`.
    private static func stepContainerBackward(
        _ nsText: NSString, at idx: Int, stack: inout [(closeIdx: Int, expectedOpen: unichar)],
        state: inout AuthScanState
    ) -> Int {
        let ch = nsText.character(at: idx)
        if ch == 0x22 {
            guard !isEscapedQuote(nsText, at: idx) else { return Int.min }
            let strStart = scanJsonStringStartBackward(nsText, from: idx)
            return strStart >= 0 ? -((strStart - 1) + 2) : Int.min
        }
        if ch == 0x7D || ch == 0x5D {
            if let innerOpen = state.closeToOpenMap[idx] {
                return innerOpen >= 0 ? -((innerOpen - 1) + 2) : Int.min
            }
            stack.append((idx, ch == 0x7D ? 0x7B : 0x5B))
            return -((idx - 1) + 2)
        }
        if ch == 0x7B || ch == 0x5B {
            return matchContainerOpener(nsText, at: idx, openChar: ch, stack: &stack, state: &state)
        }
        return -((idx - 1) + 2)
    }

    private static func matchContainerOpener(
        _ nsText: NSString, at idx: Int, openChar: unichar,
        stack: inout [(closeIdx: Int, expectedOpen: unichar)], state: inout AuthScanState
    ) -> Int {
        guard let top = stack.popLast(), top.expectedOpen == openChar else { return Int.min }
        guard tryParseJsonValue(nsText, from: idx, state: &state) == top.closeIdx + 1 else {
            state.closeToOpenMap[top.closeIdx] = -1
            return Int.min
        }
        state.closeToOpenMap[top.closeIdx] = idx
        return idx
    }

    private static func isJsonValuePrefixStop(_ ch: unichar) -> Bool {
        isHorizSpace(ch) || isNewline(ch) || ch == 0x3A || ch == 0x2C || ch == 0x5B
    }

    static func isJsonMemberContinuationDelimiter(_ nsText: NSString, at pos: Int) -> Bool {
        let ch = nsText.character(at: pos)
        if ch == 0x7D {
            guard pos + 1 < nsText.length else { return true }
            let after = nsText.character(at: pos + 1)
            return isHorizSpace(after) || isNewline(after) || isJsonDelimiter(after) || after == 0x29 || after == 0x3B
        }
        guard ch == 0x2C else { return false }
        let next = skipAuthWhitespace(nsText, from: pos + 1, len: nsText.length, allowNewlines: true)
        guard next < nsText.length && nsText.character(at: next) == 0x22 else { return false }
        let strEnd = scanJsonStringEnd(nsText, from: next + 1, len: nsText.length)
        guard strEnd > 0 else { return false }
        let afterKey = skipAuthWhitespace(nsText, from: strEnd, len: nsText.length, allowNewlines: true)
        return afterKey < nsText.length && nsText.character(at: afterKey) == 0x3A
    }

    static func redactJsonObject(
        _ nsText: NSString, from bracePos: Int, isJsonMember: Bool, allowTruncatedObj: Bool, state: inout AuthScanState
    ) -> Int? {
        let objEnd = tryParseJsonValue(nsText, from: bracePos, state: &state)
        if objEnd > bracePos {
            state.appendRedacted(
                nsText, start: bracePos, end: objEnd, replacement: isJsonMember ? "\"[redacted]\"" : "[redacted]"
            )
            return objEnd
        }
        guard isJsonMember || allowTruncatedObj else { return nil }
        state.appendRedacted(nsText, start: bracePos, end: nsText.length, replacement: "\"[redacted]\"")
        return nsText.length
    }

    static func isJsonPrimitiveStop(_ ch: unichar) -> Bool {
        isHorizSpace(ch) || isNewline(ch) || isJsonDelimiter(ch)
    }

    private static let jsonNumberRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#
    )

    static func isJsonNumber(_ token: String) -> Bool {
        guard let regex = jsonNumberRegex else { return false }
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return regex.firstMatch(in: token, options: [], range: range) != nil
    }

    static func isAuthKeyWordChar(_ ch: unichar) -> Bool {
        CoreTelemetryService.isASCIILetter(ch) || CoreTelemetryService.isASCIIDigit(ch) || ch == 0x5F || ch == 0x2D
    }

    static func matchesASCII(_ nsText: NSString, at pos: Int, literal: String, len: Int) -> Bool {
        let litBytes = Array(literal.utf8)
        guard pos + litBytes.count <= len else { return false }
        for offset in 0..<litBytes.count {
            var actual = nsText.character(at: pos + offset)
            var expected = unichar(litBytes[offset])
            if actual >= 0x41 && actual <= 0x5A { actual += 0x20 }
            if expected >= 0x41 && expected <= 0x5A { expected += 0x20 }
            if actual != expected { return false }
        }
        return true
    }
}

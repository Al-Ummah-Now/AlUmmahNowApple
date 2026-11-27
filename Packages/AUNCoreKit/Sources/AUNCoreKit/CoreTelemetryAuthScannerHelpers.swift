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

    static func isPrecededByJsonMemberDelimiter(
        _ nsText: NSString, before pos: Int, state: inout AuthScanState
    ) -> Bool {
        var idx = pos - 1
        while idx >= 0 && (isHorizSpace(nsText.character(at: idx)) || isNewline(nsText.character(at: idx))) { idx -= 1 }
        guard idx >= 0 else { return false }
        let ch = nsText.character(at: idx)
        if ch == 0x7B { return true }
        guard ch == 0x2C else { return false }
        return isPrecededByJsonValue(nsText, before: idx, state: &state)
    }

    private static func isPrecededByJsonValue(
        _ nsText: NSString, before commaPos: Int, state: inout AuthScanState
    ) -> Bool {
        var prev = commaPos - 1
        while prev >= 0 && (isHorizSpace(nsText.character(at: prev)) || isNewline(nsText.character(at: prev))) {
            prev -= 1
        }
        guard prev >= 0 else { return false }
        let ch = nsText.character(at: prev)
        if ch == 0x22 {
            let strStart = scanJsonStringStartBackward(nsText, from: prev)
            return strStart >= 0 && isPrecededByColon(nsText, before: strStart)
        }
        if ch == 0x7D {
            let objStart = scanContainerStartBackward(nsText, closePos: prev, isBrace: true, state: &state)
            return objStart >= 0 && isPrecededByColon(nsText, before: objStart)
        }
        if ch == 0x5D {
            let arrStart = scanContainerStartBackward(nsText, closePos: prev, isBrace: false, state: &state)
            return arrStart >= 0 && isPrecededByColon(nsText, before: arrStart)
        }
        if ch >= 0x30 && ch <= 0x39 {
            var start = prev
            while start >= 0 && !isJsonValuePrefixStop(nsText.character(at: start)) { start -= 1 }
            let token = nsText.substring(with: NSRange(location: start + 1, length: prev - start))
            return isJsonNumber(token) && isPrecededByColon(nsText, before: start + 1)
        }
        return matchesJsonKeywordEndingAt(nsText, end: prev, keyword: "true")
            || matchesJsonKeywordEndingAt(nsText, end: prev, keyword: "false")
            || matchesJsonKeywordEndingAt(nsText, end: prev, keyword: "null")
    }

    private static func isPrecededByColon(_ nsText: NSString, before pos: Int) -> Bool {
        var idx = pos - 1
        while idx >= 0 && (isHorizSpace(nsText.character(at: idx)) || isNewline(nsText.character(at: idx))) { idx -= 1 }
        return idx >= 0 && nsText.character(at: idx) == 0x3A
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
        var idx = closeQuotePos - 1
        while idx >= 0 {
            let ch = nsText.character(at: idx)
            if isNewline(ch) { return -1 }
            if ch == 0x22 && !isEscapedQuote(nsText, at: idx) { return idx }
            idx -= 1
        }
        return -1
    }

    private static func scanContainerStartBackward(
        _ nsText: NSString, closePos: Int, isBrace: Bool, state: inout AuthScanState
    ) -> Int {
        if let cached = state.closeToOpenMap[closePos] { return cached }
        let floor = isBrace ? state.failedBraceBack : state.failedBracketBack
        let matched = walkContainerBackward(
            nsText, closePos: closePos, isBrace: isBrace, floor: floor, map: &state.closeToOpenMap
        )
        if matched < 0 {
            if isBrace {
                state.failedBraceBack = max(state.failedBraceBack, closePos)
            } else {
                state.failedBracketBack = max(state.failedBracketBack, closePos)
            }
        }
        return matched
    }

    private static func walkContainerBackward(
        _ nsText: NSString, closePos: Int, isBrace: Bool, floor: Int, map: inout [Int: Int]
    ) -> Int {
        let open: unichar = isBrace ? 0x7B : 0x5B
        let close: unichar = isBrace ? 0x7D : 0x5D
        var stack: [Int] = []
        var idx = closePos
        while idx > floor {
            let ch = nsText.character(at: idx)
            if ch == 0x22 && !isEscapedQuote(nsText, at: idx) {
                let strStart = scanJsonStringStartBackward(nsText, from: idx)
                if strStart < 0 { break }
                idx = strStart - 1
                continue
            }
            if ch == close {
                if let innerOpen = map[idx] {
                    if innerOpen < 0 { break }
                    idx = innerOpen - 1
                    continue
                }
                stack.append(idx)
            } else if ch == open, let matchedClose = stack.popLast() {
                map[matchedClose] = idx
                if stack.isEmpty { return idx }
            }
            idx -= 1
        }
        for unmatched in stack { map[unmatched] = -1 }
        return -1
    }

    private static func isJsonValuePrefixStop(_ ch: unichar) -> Bool {
        isHorizSpace(ch) || isNewline(ch) || ch == 0x3A || ch == 0x2C || ch == 0x5B
    }

    private static func matchesJsonKeywordEndingAt(_ nsText: NSString, end: Int, keyword: String) -> Bool {
        let kwLen = keyword.utf16.count
        let start = end - kwLen + 1
        guard start >= 0 else { return false }
        guard nsText.substring(with: NSRange(location: start, length: kwLen)) == keyword else { return false }
        return isPrecededByColon(nsText, before: start)
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
        _ nsText: NSString, from bracePos: Int, isJsonMember: Bool, state: inout AuthScanState
    ) -> Int? {
        if let objEnd = scanBalancedJsonObjectEnd(nsText, from: bracePos, state: &state) {
            state.appendRedacted(
                nsText, start: bracePos, end: objEnd, replacement: isJsonMember ? "\"[redacted]\"" : "[redacted]"
            )
            return objEnd
        }
        guard isJsonMember else { return nil }
        state.appendRedacted(nsText, start: bracePos, end: nsText.length, replacement: "\"[redacted]\"")
        return nsText.length
    }

    private static func scanBalancedJsonObjectEnd(
        _ nsText: NSString, from bracePos: Int, state: inout AuthScanState
    ) -> Int? {
        guard bracePos < nsText.length && nsText.character(at: bracePos) == 0x7B else { return nil }
        if let cached = state.braceMap[bracePos] { return cached > 0 ? cached : nil }
        let endPos = scanAndMemoizeBracesFrom(nsText, bracePos: bracePos, map: &state.braceMap)
        return endPos > 0 ? endPos : nil
    }

    private static func scanAndMemoizeBracesFrom(
        _ nsText: NSString, bracePos: Int, map: inout [Int: Int]
    ) -> Int {
        let len = nsText.length
        var stack: [Int] = []
        var noCloseQuoteBefore = -1
        var idx = bracePos
        while idx < len {
            let ch = nsText.character(at: idx)
            if ch == 0x22 && idx >= noCloseQuoteBefore {
                let strEnd = scanJsonStringEnd(nsText, from: idx + 1, len: len)
                if strEnd > 0 { idx = strEnd; continue }
                noCloseQuoteBefore = -strEnd - 1
            } else if ch == 0x7B {
                if let known = map[idx] {
                    if known > idx { idx = known; continue }
                    for open in stack { map[open] = -1 }
                    return -1
                }
                stack.append(idx)
            } else if ch == 0x7D, let open = stack.popLast() {
                map[open] = idx + 1
                if stack.isEmpty { return idx + 1 }
            }
            idx += 1
        }
        for open in stack { map[open] = -1 }
        return -1
    }

    private static func scanJsonStringEnd(_ nsText: NSString, from start: Int, len: Int) -> Int {
        var idx = start
        var escaped = false
        while idx < len {
            let ch = nsText.character(at: idx)
            if isNewline(ch) { return -(idx + 1) }
            if ch == 0x22 && !escaped { return idx + 1 }
            escaped = ch == 0x5C && !escaped
            idx += 1
        }
        return -(len + 1)
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

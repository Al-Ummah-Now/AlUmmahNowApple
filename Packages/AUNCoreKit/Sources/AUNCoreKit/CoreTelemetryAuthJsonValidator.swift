import Foundation

extension CoreTelemetryAuthScanner {
    private struct JsonFrame {
        let openPos: Int
        let isObject: Bool
    }

    static func scanJsonStringEnd(_ nsText: NSString, from start: Int, len: Int) -> Int {
        var idx = start
        while idx < len {
            let ch = nsText.character(at: idx)
            if ch < 0x20 { return -(idx + 1) }
            if ch == 0x22 { return idx + 1 }
            if ch == 0x5C {
                let step = jsonEscapeStep(nsText, at: idx, len: len)
                if step < 0 { return -(idx + 2) }
                idx += step
            } else {
                idx += 1
            }
        }
        return -(len + 1)
    }

    private static func jsonEscapeStep(_ nsText: NSString, at slashPos: Int, len: Int) -> Int {
        guard slashPos + 1 < len else { return -1 }
        let esc = nsText.character(at: slashPos + 1)
        if isSimpleJsonEscape(esc) { return 2 }
        if esc == 0x75 && slashPos + 5 < len && isHex4(nsText, at: slashPos + 2) { return 6 }
        return -1
    }

    private static func isSimpleJsonEscape(_ ch: unichar) -> Bool {
        ch == 0x22 || ch == 0x5C || ch == 0x2F || ch == 0x62
            || ch == 0x66 || ch == 0x6E || ch == 0x72 || ch == 0x74
    }

    private static func isHex4(_ nsText: NSString, at pos: Int) -> Bool {
        for offset in 0..<4 {
            let ch = nsText.character(at: pos + offset)
            let isDigit = ch >= 0x30 && ch <= 0x39
            let isLower = ch >= 0x61 && ch <= 0x66
            let isUpper = ch >= 0x41 && ch <= 0x46
            if !isDigit && !isLower && !isUpper { return false }
        }
        return true
    }

    static func tryParseJsonValue(
        _ nsText: NSString, from startPos: Int, state: inout AuthScanState
    ) -> Int {
        let len = nsText.length
        guard startPos < len else { return -1 }
        if let cached = state.validJsonValueEnd[startPos] { return cached }
        return runJsonValueParse(nsText, startPos: startPos, len: len, cache: &state.validJsonValueEnd)
    }

    private static func runJsonValueParse(
        _ nsText: NSString, startPos: Int, len: Int, cache: inout [Int: Int]
    ) -> Int {
        var stack: [JsonFrame] = []
        var pos = startPos
        var expectingValue = true
        while true {
            pos = skipJsonWhitespaceForward(nsText, from: pos, len: len)
            let step =
                expectingValue
                ? parseJsonValueStart(nsText, pos: &pos, len: len, stack: &stack, cache: &cache)
                : parseJsonAfterValue(nsText, pos: &pos, len: len, stack: &stack, cache: &cache)
            if step < 0 { return failJsonParse(startPos: startPos, stack: stack, cache: &cache) }
            if step == 1 {
                expectingValue = false
                if stack.isEmpty { return pos }
            } else if step == 2 {
                expectingValue = true
            }
        }
    }

    private static func failJsonParse(
        startPos: Int, stack: [JsonFrame], cache: inout [Int: Int]
    ) -> Int {
        for frame in stack { cache[frame.openPos] = -1 }
        cache[startPos] = -1
        return -1
    }

    /// Returns -1 on error, 0 to continue expecting a value, 1 when a complete value finished.
    private static func parseJsonValueStart(
        _ nsText: NSString, pos: inout Int, len: Int, stack: inout [JsonFrame], cache: inout [Int: Int]
    ) -> Int {
        guard pos < len else { return -1 }
        let ch = nsText.character(at: pos)
        if ch == 0x7B { return openJsonObject(nsText, pos: &pos, len: len, stack: &stack, cache: &cache) }
        if ch == 0x5B { return openJsonArray(nsText, pos: &pos, len: len, stack: &stack, cache: &cache) }
        let scalarEnd = scanJsonScalarEnd(nsText, from: pos, len: len)
        guard scalarEnd > pos else { return -1 }
        pos = scalarEnd
        return 1
    }

    private static func openJsonObject(
        _ nsText: NSString, pos: inout Int, len: Int, stack: inout [JsonFrame], cache: inout [Int: Int]
    ) -> Int {
        if let cached = cache[pos] {
            guard cached > pos else { return -1 }
            pos = cached
            return 1
        }
        let openPos = pos
        pos = skipJsonWhitespaceForward(nsText, from: pos + 1, len: len)
        if pos < len && nsText.character(at: pos) == 0x7D {
            cache[openPos] = pos + 1
            pos += 1
            return 1
        }
        guard advanceOverObjectKeyColon(nsText, pos: &pos, len: len) else { return -1 }
        stack.append(JsonFrame(openPos: openPos, isObject: true))
        return 0
    }

    private static func openJsonArray(
        _ nsText: NSString, pos: inout Int, len: Int, stack: inout [JsonFrame], cache: inout [Int: Int]
    ) -> Int {
        if let cached = cache[pos] {
            guard cached > pos else { return -1 }
            pos = cached
            return 1
        }
        let openPos = pos
        pos = skipJsonWhitespaceForward(nsText, from: pos + 1, len: len)
        if pos < len && nsText.character(at: pos) == 0x5D {
            cache[openPos] = pos + 1
            pos += 1
            return 1
        }
        stack.append(JsonFrame(openPos: openPos, isObject: false))
        return 0
    }

    /// Returns -1 on error, 1 when a container closed, 2 when comma advances to next value.
    private static func parseJsonAfterValue(
        _ nsText: NSString, pos: inout Int, len: Int, stack: inout [JsonFrame], cache: inout [Int: Int]
    ) -> Int {
        guard pos < len, let top = stack.last else { return -1 }
        let ch = nsText.character(at: pos)
        if top.isObject {
            if ch == 0x7D {
                stack.removeLast()
                cache[top.openPos] = pos + 1
                pos += 1
                return 1
            }
            guard ch == 0x2C else { return -1 }
            pos = skipJsonWhitespaceForward(nsText, from: pos + 1, len: len)
            return advanceOverObjectKeyColon(nsText, pos: &pos, len: len) ? 2 : -1
        }
        if ch == 0x5D {
            stack.removeLast()
            cache[top.openPos] = pos + 1
            pos += 1
            return 1
        }
        guard ch == 0x2C else { return -1 }
        pos += 1
        return 2
    }

    private static func advanceOverObjectKeyColon(_ nsText: NSString, pos: inout Int, len: Int) -> Bool {
        guard pos < len && nsText.character(at: pos) == 0x22 else { return false }
        let keyEnd = scanJsonStringEnd(nsText, from: pos + 1, len: len)
        guard keyEnd > 0 else { return false }
        let colon = skipJsonWhitespaceForward(nsText, from: keyEnd, len: len)
        guard colon < len && nsText.character(at: colon) == 0x3A else { return false }
        pos = colon + 1
        return true
    }

    private static func scanJsonScalarEnd(_ nsText: NSString, from pos: Int, len: Int) -> Int {
        let ch = nsText.character(at: pos)
        if ch == 0x22 { return scanJsonStringEnd(nsText, from: pos + 1, len: len) }
        if ch == 0x74 { return matchesExact(nsText, at: pos, literal: "true", len: len) ? pos + 4 : -1 }
        if ch == 0x66 { return matchesExact(nsText, at: pos, literal: "false", len: len) ? pos + 5 : -1 }
        if ch == 0x6E { return matchesExact(nsText, at: pos, literal: "null", len: len) ? pos + 4 : -1 }
        return scanJsonNumberEnd(nsText, from: pos, len: len)
    }

    private static func matchesExact(_ nsText: NSString, at pos: Int, literal: String, len: Int) -> Bool {
        let litLen = literal.utf16.count
        guard pos + litLen <= len else { return false }
        return nsText.substring(with: NSRange(location: pos, length: litLen)) == literal
    }

    private static func scanJsonNumberEnd(_ nsText: NSString, from pos: Int, len: Int) -> Int {
        var idx = pos
        if idx < len && nsText.character(at: idx) == 0x2D { idx += 1 }
        idx = scanJsonIntPart(nsText, from: idx, len: len)
        guard idx > 0 else { return -1 }
        idx = scanJsonFractionPart(nsText, from: idx, len: len)
        guard idx > 0 else { return -1 }
        return scanJsonExponentPart(nsText, from: idx, len: len)
    }

    private static func scanJsonIntPart(_ nsText: NSString, from pos: Int, len: Int) -> Int {
        guard pos < len && CoreTelemetryService.isASCIIDigit(nsText.character(at: pos)) else { return -1 }
        if nsText.character(at: pos) == 0x30 { return pos + 1 }
        var idx = pos + 1
        while idx < len && CoreTelemetryService.isASCIIDigit(nsText.character(at: idx)) { idx += 1 }
        return idx
    }

    private static func scanJsonFractionPart(_ nsText: NSString, from pos: Int, len: Int) -> Int {
        guard pos < len && nsText.character(at: pos) == 0x2E else { return pos }
        var idx = pos + 1
        guard idx < len && CoreTelemetryService.isASCIIDigit(nsText.character(at: idx)) else { return -1 }
        while idx < len && CoreTelemetryService.isASCIIDigit(nsText.character(at: idx)) { idx += 1 }
        return idx
    }

    private static func scanJsonExponentPart(_ nsText: NSString, from pos: Int, len: Int) -> Int {
        guard pos < len && (nsText.character(at: pos) == 0x65 || nsText.character(at: pos) == 0x45) else { return pos }
        var idx = pos + 1
        if idx < len && (nsText.character(at: idx) == 0x2B || nsText.character(at: idx) == 0x2D) { idx += 1 }
        guard idx < len && CoreTelemetryService.isASCIIDigit(nsText.character(at: idx)) else { return -1 }
        while idx < len && CoreTelemetryService.isASCIIDigit(nsText.character(at: idx)) { idx += 1 }
        return idx
    }

    static func skipJsonWhitespaceForward(_ nsText: NSString, from start: Int, len: Int) -> Int {
        var idx = start
        while idx < len && (isHorizSpace(nsText.character(at: idx)) || isNewline(nsText.character(at: idx))) {
            idx += 1
        }
        return idx
    }
}

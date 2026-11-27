import Foundation

extension CoreTelemetryService {
    private static let urlPathSecretRules: [NSRegularExpression?] = [
        try? NSRegularExpression(pattern: #"((?:^|/|%2[fF])webhooks?(?:/|%2[fF]))[^\s?#]+"#, options: [.caseInsensitive]),
        try? NSRegularExpression(
            pattern:
                #"(https?://hooks\.slack(?:-gov)?\.com\.?(?::\d+)?(?:/|%2[fF])(?:services|workflows|triggers)(?:/|%2[fF]))[^\s?#]+"#,
            options: [.caseInsensitive]
        ),
        try? NSRegularExpression(pattern: #"((?:/|%2[fF])bot\d+:)[^/\s?#]+"#, options: [.caseInsensitive]),
    ]

    static func redactURLPathSecrets(_ url: String) -> String {
        var result = url
        for regex in urlPathSecretRules {
            guard let regex else { continue }
            result = replaceURLPathSecret(result, regex: regex)
        }
        return result
    }

    private static func replaceURLPathSecret(_ url: String, regex: NSRegularExpression) -> String {
        if !url.contains("%") {
            let range = NSRange(url.startIndex..<url.endIndex, in: url)
            return regex.stringByReplacingMatches(in: url, options: [], range: range, withTemplate: "$1[redacted]")
        }
        let (decoded, origOffsets) = decodeURLForPathSecretMatch(url)
        let nsDecoded = decoded as NSString
        let matches = regex.matches(in: decoded, options: [], range: NSRange(location: 0, length: nsDecoded.length))
        guard !matches.isEmpty else { return url }
        let nsURL = url as NSString
        var rebuilt = ""
        var copied = 0
        for match in matches {
            let g1 = match.range(at: 1)
            let secretStart = origOffsets[g1.location + g1.length]
            if secretStart < copied { continue }
            let secretEnd = origOffsets[match.range.location + match.range.length]
            rebuilt += nsURL.substring(with: NSRange(location: copied, length: secretStart - copied))
            rebuilt += "[redacted]"
            copied = secretEnd
        }
        guard copied > 0 else { return url }
        rebuilt += nsURL.substring(from: copied)
        return rebuilt
    }

    private static func decodeURLForPathSecretMatch(_ url: String) -> (String, [Int]) {
        let nsURL = url as NSString
        let len = nsURL.length
        var decodedUnits: [unichar] = []
        decodedUnits.reserveCapacity(len)
        var offsets: [Int] = []
        offsets.reserveCapacity(len + 1)
        var idx = 0
        while idx < len {
            offsets.append(idx)
            let ch = nsURL.character(at: idx)
            if ch == 0x25, idx + 2 < len,
                let byteVal = parseHexByte(nsURL.character(at: idx + 1), nsURL.character(at: idx + 2)),
                isDecodablePathSecretByte(byteVal)
            {
                decodedUnits.append(unichar(byteVal))
                idx += 3
            } else {
                decodedUnits.append(ch)
                idx += 1
            }
        }
        offsets.append(len)
        return (String(utf16CodeUnits: decodedUnits, count: decodedUnits.count), offsets)
    }

    private static func isDecodablePathSecretByte(_ byteVal: UInt8) -> Bool {
        byteVal >= 0x21 && byteVal <= 0x7E && byteVal != 0x2F && byteVal != 0x3F && byteVal != 0x23
    }

    private static func parseHexByte(_ hi: unichar, _ lo: unichar) -> UInt8? {
        guard let h = hexNibble(hi), let l = hexNibble(lo) else { return nil }
        return (h << 4) | l
    }

    private static func hexNibble(_ ch: unichar) -> UInt8? {
        if ch >= 0x30 && ch <= 0x39 { return UInt8(ch - 0x30) }
        if ch >= 0x61 && ch <= 0x66 { return UInt8(ch - 0x61 + 10) }
        if ch >= 0x41 && ch <= 0x46 { return UInt8(ch - 0x41 + 10) }
        return nil
    }

    struct URLContinuationResult {
        let replaceBase: Bool
        let baseURL: String
        let keepBaseTail: Bool
        let middle: String
        let qfToken: String
        let tail: String
        let endPos: Int
    }

    struct ContinuationLimits {
        var failedContMax = 0
        var unclosedDoubleQuoteEnd = 0
        var unclosedSingleQuoteEnd = 0
    }

    static func formatURLContinuation(
        _ ext: URLContinuationResult, prefix: String, baseRedacted: String, baseTail: String, vaultedURLs: inout [String]
    ) -> String {
        if ext.replaceBase {
            let idx = vaultedURLs.count
            vaultedURLs.append(ext.baseURL)
            return "\(prefix)\(idx)\u{001F}\(ext.tail)"
        }
        let baseIdx = vaultedURLs.count
        vaultedURLs.append(baseRedacted)
        var piece = "\(prefix)\(baseIdx)\u{001F}"
        if ext.keepBaseTail { piece += baseTail }
        piece +=
            ext.middle.contains("://")
            ? Self.vaultNonFileURLsInto(ext.middle, prefix: prefix, vaultedURLs: &vaultedURLs)
            : ext.middle
        if !ext.qfToken.isEmpty {
            let qfIdx = vaultedURLs.count
            vaultedURLs.append(ext.qfToken)
            piece += "\(prefix)\(qfIdx)\u{001F}"
        }
        return piece + ext.tail
    }

    private struct ContinuationContext {
        let span: URLScanMatch
        let rawURL: String
        let baseTail: String
        let webhookProbe: String?
        let allowDoubleQuotes: Bool
        let allowSingleQuotes: Bool
        let pathEnd: Int
    }

    static func extendURLContinuation(
        _ nsText: NSString, span: URLScanMatch, rawURL: String, baseTail: String, limits: inout ContinuationLimits
    ) -> URLContinuationResult? {
        let len = nsText.length
        guard !span.hasQueryOrFragment && span.totalEnd >= limits.failedContMax && span.totalEnd < len else { return nil }
        guard isURLContinuationStarter(nsText.character(at: span.totalEnd)) else { return nil }
        let allowDoubleQuotes =
            span.totalEnd >= limits.unclosedDoubleQuoteEnd && !(span.start > 0 && nsText.character(at: span.start - 1) == 0x22)
        let allowSingleQuotes =
            span.totalEnd >= limits.unclosedSingleQuoteEnd && !(span.start > 0 && nsText.character(at: span.start - 1) == 0x27)
        let probeInput = rawURL + "x"
        let probe = Self.redactURLPathSecrets(probeInput)
        let webhookProbe = (probe != probeInput && probe.hasSuffix("[redacted]")) ? probe : nil
        var scanState = ContinuationScanState(
            allowDoubleQuotes: allowDoubleQuotes, allowSingleQuotes: allowSingleQuotes,
            stopAtSchemes: webhookProbe == nil
        )
        let pathEnd = scanURLContinuation(nsText, start: span.totalEnd, state: &scanState)
        let ctx = ContinuationContext(
            span: span, rawURL: rawURL, baseTail: baseTail, webhookProbe: webhookProbe,
            allowDoubleQuotes: allowDoubleQuotes, allowSingleQuotes: allowSingleQuotes, pathEnd: pathEnd
        )
        if let qfResult = extendURLContinuationQuery(nsText, ctx: ctx) { return qfResult }
        if let secretResult = extendURLContinuationSecret(nsText, ctx: ctx) { return secretResult }
        recordFailedContinuation(scanState, pathEnd: pathEnd, limits: &limits)
        return nil
    }

    private static func recordFailedContinuation(
        _ state: ContinuationScanState, pathEnd: Int, limits: inout ContinuationLimits
    ) {
        if state.quoteChar == 0x22 && pathEnd > limits.unclosedDoubleQuoteEnd {
            limits.unclosedDoubleQuoteEnd = pathEnd
        } else if state.quoteChar == 0x27 && pathEnd > limits.unclosedSingleQuoteEnd {
            limits.unclosedSingleQuoteEnd = pathEnd
        }
        if !state.sawInnerScheme && pathEnd > limits.failedContMax { limits.failedContMax = pathEnd }
    }

    private static func extendURLContinuationQuery(
        _ nsText: NSString, ctx: ContinuationContext
    ) -> URLContinuationResult? {
        let len = nsText.length
        guard ctx.pathEnd > ctx.span.totalEnd && ctx.pathEnd < len else { return nil }
        let nextCh = nsText.character(at: ctx.pathEnd)
        guard nextCh == 0x3F || nextCh == 0x23 else { return nil }
        let qfEnd = Self.scanQueryOrFragment(nsText, start: ctx.pathEnd, len: len)
        let qf = nsText.substring(with: NSRange(location: ctx.pathEnd, length: qfEnd - ctx.pathEnd))
        let (cleanQF, qfTail) = Self.trimQueryOrFragmentDelimiters(qf, nsText: nsText, matchStart: ctx.span.start)
        let qfToken = "\(cleanQF.first.map(String.init) ?? "?")[redacted]"
        if let webhookProbe = ctx.webhookProbe {
            return URLContinuationResult(
                replaceBase: true, baseURL: "\(webhookProbe)\(qfToken)", keepBaseTail: false,
                middle: "", qfToken: "", tail: qfTail, endPos: qfEnd
            )
        }
        let baseRedacted = Self.redactURLPathSecrets(ctx.rawURL)
        let prefixRedacted = Self.redactURLPathSecrets(
            nsText.substring(with: NSRange(location: ctx.span.start, length: ctx.pathEnd - ctx.span.start)))
        if prefixRedacted == baseRedacted || prefixRedacted == "\(baseRedacted)[redacted]" {
            return URLContinuationResult(
                replaceBase: true, baseURL: "\(prefixRedacted)\(qfToken)", keepBaseTail: false,
                middle: "", qfToken: "", tail: qfTail, endPos: qfEnd
            )
        }
        let middle = continuationMiddle(
            prefixRedacted, baseRedacted: baseRedacted, nsText: nsText, from: ctx.span.totalEnd, to: ctx.pathEnd
        )
        let keepTail = !ctx.baseTail.isEmpty && baseRedacted.hasSuffix(ctx.baseTail)
        return URLContinuationResult(
            replaceBase: false, baseURL: "", keepBaseTail: keepTail,
            middle: middle, qfToken: qfToken, tail: qfTail, endPos: qfEnd
        )
    }

    private static func extendURLContinuationSecret(
        _ nsText: NSString, ctx: ContinuationContext
    ) -> URLContinuationResult? {
        let end = trimWebhookContinuationEnd(nsText, ctx: ctx)
        guard end > ctx.span.totalEnd else { return nil }
        let extTail = nsText.substring(with: NSRange(location: end, length: ctx.pathEnd - end))
        if let webhookProbe = ctx.webhookProbe {
            return URLContinuationResult(
                replaceBase: true, baseURL: webhookProbe, keepBaseTail: false,
                middle: "", qfToken: "", tail: extTail, endPos: ctx.pathEnd
            )
        }
        let baseRedacted = Self.redactURLPathSecrets(ctx.rawURL)
        let extRedacted = Self.redactURLPathSecrets(
            nsText.substring(with: NSRange(location: ctx.span.start, length: end - ctx.span.start)))
        let addedRaw = nsText.substring(with: NSRange(location: ctx.span.totalEnd, length: end - ctx.span.totalEnd))
        guard extRedacted != baseRedacted + addedRaw else { return nil }
        if extRedacted == baseRedacted || extRedacted == "\(baseRedacted)[redacted]" {
            return URLContinuationResult(
                replaceBase: true, baseURL: extRedacted, keepBaseTail: false,
                middle: "", qfToken: "", tail: extTail, endPos: ctx.pathEnd
            )
        }
        let middle = continuationMiddle(
            extRedacted, baseRedacted: baseRedacted, nsText: nsText, from: ctx.span.totalEnd, to: end
        )
        let keepTail = !ctx.baseTail.isEmpty && baseRedacted.hasSuffix(ctx.baseTail)
        return URLContinuationResult(
            replaceBase: false, baseURL: "", keepBaseTail: keepTail,
            middle: middle, qfToken: "", tail: extTail, endPos: ctx.pathEnd
        )
    }

    private static func continuationMiddle(
        _ redacted: String, baseRedacted: String, nsText: NSString, from start: Int, to end: Int
    ) -> String {
        if redacted.hasPrefix(baseRedacted) {
            return String(redacted.dropFirst(baseRedacted.count))
        }
        return nsText.substring(with: NSRange(location: start, length: end - start))
    }

    private static func isURLContinuationStarter(_ ch: unichar) -> Bool {
        ch == 0x2C || ch == 0x28 || ch == 0x5B || ch == 0x29 || ch == 0x5D || ch == 0x7B || ch == 0x7D
    }

    private static func isURLContinuationSeparator(_ ch: unichar) -> Bool {
        ch == 0x2C || ch == 0x3B || ch == 0x28 || ch == 0x5B || ch == 0x29 || ch == 0x5D || ch == 0x7B || ch == 0x7D
            || ch == 0x27
    }

    private static func isURLContinuationStopChar(_ ch: unichar) -> Bool {
        ch == 0x3C || ch == 0x3E || ch == 0x5C || ch == 0x3F || ch == 0x23 || ch == 0x0D || ch == 0x0A
    }

    private static func isURLScheme(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        guard pos < len && Self.isASCIILetter(nsText.character(at: pos)) else { return false }
        var idx = pos + 1
        while idx < len && VaultLineTracker.isURLSchemeChar(nsText.character(at: idx)) { idx += 1 }
        guard idx - pos >= 2 && idx + 2 < len else { return false }
        return nsText.character(at: idx) == 0x3A
            && nsText.character(at: idx + 1) == 0x2F
            && nsText.character(at: idx + 2) == 0x2F
    }

    private struct ContinuationScanState {
        let allowDoubleQuotes: Bool
        let allowSingleQuotes: Bool
        let stopAtSchemes: Bool
        var groupStack: [unichar] = []
        var quoteChar: unichar = 0
        var sawInnerScheme = false
    }

    private static func scanURLContinuation(
        _ nsText: NSString, start: Int, state: inout ContinuationScanState
    ) -> Int {
        let len = nsText.length
        var pos = start
        while pos < len {
            let next =
                state.quoteChar != 0
                ? stepQuotedContinuation(nsText, pos: pos, len: len, state: &state)
                : stepUnquotedContinuation(nsText, pos: pos, start: start, state: &state)
            if next < 0 { break }
            pos = next
        }
        return pos
    }

    private static func stepQuotedContinuation(
        _ nsText: NSString, pos: Int, len: Int, state: inout ContinuationScanState
    ) -> Int {
        let ch = nsText.character(at: pos)
        if ch == 0x0D || ch == 0x0A { return -1 }
        if ch == 0x3A && pos + 2 < len && nsText.character(at: pos + 1) == 0x2F && nsText.character(at: pos + 2) == 0x2F {
            state.sawInnerScheme = true
        }
        if ch == 0x5C && pos + 1 < len {
            let escaped = nsText.character(at: pos + 1)
            if escaped != 0x0D && escaped != 0x0A { return pos + 2 }
        }
        if ch == state.quoteChar { state.quoteChar = 0 }
        return pos + 1
    }

    private static func stepUnquotedContinuation(
        _ nsText: NSString, pos: Int, start: Int, state: inout ContinuationScanState
    ) -> Int {
        let len = nsText.length
        let isDrive =
            (pos == 0 || !Self.isASCIIAlphaNum(nsText.character(at: pos - 1)))
            && Self.isWindowsDriveAt(nsText, at: pos, len: len)
        if VaultLineTracker.isFileScheme(nsText, at: pos) || isDrive { return -1 }
        if state.stopAtSchemes && pos > start && isURLContinuationSeparator(nsText.character(at: pos - 1))
            && isURLScheme(nsText, at: pos, len: len)
        {
            return -1
        }
        let ch = nsText.character(at: pos)
        if VaultLineTracker.isWhitespace(ch) || isURLContinuationStopChar(ch) { return -1 }
        if ch == 0x22 || ch == 0x27 {
            let allowed = ch == 0x22 ? state.allowDoubleQuotes : state.allowSingleQuotes
            if allowed && !state.groupStack.isEmpty {
                state.quoteChar = ch
                return pos + 1
            }
            return ch == 0x22 ? -1 : pos + 1
        }
        updateURLContinuationGroupStack(ch, stack: &state.groupStack)
        return pos + 1
    }

    private static func updateURLContinuationGroupStack(_ ch: unichar, stack: inout [unichar]) {
        if ch == 0x28 || ch == 0x5B || ch == 0x7B {
            stack.append(ch)
        } else if ch == 0x29 || ch == 0x5D || ch == 0x7D {
            let expected: unichar = ch == 0x29 ? 0x28 : (ch == 0x5D ? 0x5B : 0x7B)
            if stack.last == expected { stack.removeLast() }
        }
    }

    private static func trimWebhookContinuationEnd(_ nsText: NSString, ctx: ContinuationContext) -> Int {
        var excess = countExcessGroupClosers(nsText, ctx: ctx)
        let precededByQuote = ctx.span.start > 0 && nsText.character(at: ctx.span.start - 1) == 0x27
        var end = ctx.pathEnd
        while end > ctx.span.totalEnd
            && consumeTrailingContinuationCloser(
                nsText.character(at: end - 1), precededByQuote: precededByQuote, excess: &excess)
        {
            end -= 1
        }
        return end
    }

    private static func consumeTrailingContinuationCloser(
        _ ch: unichar, precededByQuote: Bool, excess: inout (Int, Int, Int)
    ) -> Bool {
        if ch == 0x2C || ch == 0x3B || (ch == 0x27 && precededByQuote) { return true }
        if ch == 0x29 && excess.0 > 0 { excess.0 -= 1; return true }
        if ch == 0x5D && excess.1 > 0 { excess.1 -= 1; return true }
        if ch == 0x7D && excess.2 > 0 { excess.2 -= 1; return true }
        return false
    }

    private static func countExcessGroupClosers(_ nsText: NSString, ctx: ContinuationContext) -> (Int, Int, Int) {
        var counts = (0, 0, 0)
        var openGroups = 0
        var quoteChar: unichar = 0
        var idx = ctx.span.start
        while idx < ctx.pathEnd {
            let ch = nsText.character(at: idx)
            if quoteChar != 0 {
                if ch == 0x5C && idx + 1 < ctx.pathEnd { idx += 2; continue }
                if ch == quoteChar { quoteChar = 0 }
            } else if openGroups > 0
                && ((ch == 0x22 && ctx.allowDoubleQuotes) || (ch == 0x27 && ctx.allowSingleQuotes))
            {
                quoteChar = ch
            } else {
                tallyGroupCloser(ch, counts: &counts, openGroups: &openGroups)
            }
            idx += 1
        }
        return counts
    }

    private static func tallyGroupCloser(_ ch: unichar, counts: inout (Int, Int, Int), openGroups: inout Int) {
        switch ch {
        case 0x28: counts.0 -= 1; openGroups += 1
        case 0x29: counts.0 += 1; if openGroups > 0 { openGroups -= 1 }
        case 0x5B: counts.1 -= 1; openGroups += 1
        case 0x5D: counts.1 += 1; if openGroups > 0 { openGroups -= 1 }
        case 0x7B: counts.2 -= 1; openGroups += 1
        case 0x7D: counts.2 += 1; if openGroups > 0 { openGroups -= 1 }
        default: break
        }
    }
}

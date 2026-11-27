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
        piece += ext.middle
        if !ext.qfToken.isEmpty {
            let qfIdx = vaultedURLs.count
            vaultedURLs.append(ext.qfToken)
            piece += "\(prefix)\(qfIdx)\u{001F}"
        }
        return piece + ext.tail
    }

    static func extendURLContinuation(
        _ nsText: NSString, span: URLScanMatch, rawURL: String, baseTail: String, failedContMax: inout Int
    ) -> URLContinuationResult? {
        let len = nsText.length
        guard !span.hasQueryOrFragment && span.totalEnd >= failedContMax && span.totalEnd < len else { return nil }
        guard isURLContinuationStarter(nsText.character(at: span.totalEnd)) else { return nil }
        let allowGroupQuotes = !(span.start > 0 && nsText.character(at: span.start - 1) == 0x22)
        let pathEnd = scanURLContinuation(nsText, start: span.totalEnd, len: len, allowGroupQuotes: allowGroupQuotes)
        if let qfResult = extendURLContinuationQuery(
            nsText, span: span, rawURL: rawURL, baseTail: baseTail, pathEnd: pathEnd
        ) {
            return qfResult
        }
        if let secretResult = extendURLContinuationSecret(
            nsText, span: span, rawURL: rawURL, baseTail: baseTail, pathEnd: pathEnd
        ) {
            return secretResult
        }
        if pathEnd > failedContMax { failedContMax = pathEnd }
        return nil
    }

    private static func extendURLContinuationQuery(
        _ nsText: NSString, span: URLScanMatch, rawURL: String, baseTail: String, pathEnd: Int
    ) -> URLContinuationResult? {
        let len = nsText.length
        guard pathEnd > span.totalEnd && pathEnd < len else { return nil }
        let nextCh = nsText.character(at: pathEnd)
        guard nextCh == 0x3F || nextCh == 0x23 else { return nil }
        let qfEnd = Self.scanQueryOrFragment(nsText, start: pathEnd, len: len)
        let qf = nsText.substring(with: NSRange(location: pathEnd, length: qfEnd - pathEnd))
        let (cleanQF, qfTail) = Self.trimQueryOrFragmentDelimiters(qf, nsText: nsText, matchStart: span.start)
        let qfToken = "\(cleanQF.first.map(String.init) ?? "?")[redacted]"
        let baseRedacted = Self.redactURLPathSecrets(rawURL)
        let prefixRedacted = Self.redactURLPathSecrets(
            nsText.substring(with: NSRange(location: span.start, length: pathEnd - span.start)))
        if prefixRedacted == baseRedacted || prefixRedacted == "\(baseRedacted)[redacted]" {
            return URLContinuationResult(
                replaceBase: true, baseURL: "\(prefixRedacted)\(qfToken)", keepBaseTail: false,
                middle: "", qfToken: "", tail: qfTail, endPos: qfEnd
            )
        }
        let middle = continuationMiddle(
            prefixRedacted, baseRedacted: baseRedacted, nsText: nsText, from: span.totalEnd, to: pathEnd
        )
        let keepTail = !baseTail.isEmpty && baseRedacted.hasSuffix(baseTail)
        return URLContinuationResult(
            replaceBase: false, baseURL: "", keepBaseTail: keepTail,
            middle: middle, qfToken: qfToken, tail: qfTail, endPos: qfEnd
        )
    }

    private static func extendURLContinuationSecret(
        _ nsText: NSString, span: URLScanMatch, rawURL: String, baseTail: String, pathEnd: Int
    ) -> URLContinuationResult? {
        let end = trimWebhookContinuationEnd(nsText, urlStart: span.start, minEnd: span.totalEnd, scanEnd: pathEnd)
        guard end > span.totalEnd else { return nil }
        let baseRedacted = Self.redactURLPathSecrets(rawURL)
        let extRedacted = Self.redactURLPathSecrets(
            nsText.substring(with: NSRange(location: span.start, length: end - span.start)))
        let addedRaw = nsText.substring(with: NSRange(location: span.totalEnd, length: end - span.totalEnd))
        guard extRedacted != baseRedacted + addedRaw else { return nil }
        let extTail = nsText.substring(with: NSRange(location: end, length: pathEnd - end))
        if extRedacted == baseRedacted || extRedacted == "\(baseRedacted)[redacted]" {
            return URLContinuationResult(
                replaceBase: true, baseURL: extRedacted, keepBaseTail: false,
                middle: "", qfToken: "", tail: extTail, endPos: pathEnd
            )
        }
        let middle = continuationMiddle(
            extRedacted, baseRedacted: baseRedacted, nsText: nsText, from: span.totalEnd, to: end
        )
        let keepTail = !baseTail.isEmpty && baseRedacted.hasSuffix(baseTail)
        return URLContinuationResult(
            replaceBase: false, baseURL: "", keepBaseTail: keepTail,
            middle: middle, qfToken: "", tail: extTail, endPos: pathEnd
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

    private static func isURLContinuationStopChar(_ ch: unichar, allowQuote: Bool) -> Bool {
        if ch == 0x22 { return !allowQuote }
        return ch == 0x3C || ch == 0x3E || ch == 0x5C || ch == 0x3F || ch == 0x23 || ch == 0x0D || ch == 0x0A
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

    private static func scanURLContinuation(_ nsText: NSString, start: Int, len: Int, allowGroupQuotes: Bool) -> Int {
        var pos = start
        var groupDepth = 0
        while pos < len {
            let ch = nsText.character(at: pos)
            if shouldBreakURLContinuation(
                nsText, pos: pos, start: start, len: len, allowQuote: allowGroupQuotes && groupDepth > 0
            ) {
                break
            }
            updateURLContinuationGroupDepth(ch, depth: &groupDepth)
            pos += 1
        }
        return pos
    }

    private static func shouldBreakURLContinuation(
        _ nsText: NSString, pos: Int, start: Int, len: Int, allowQuote: Bool
    ) -> Bool {
        if VaultLineTracker.isFileScheme(nsText, at: pos) || Self.isWindowsDriveAt(nsText, at: pos, len: len) {
            return true
        }
        if pos > start && isURLContinuationSeparator(nsText.character(at: pos - 1))
            && isURLScheme(nsText, at: pos, len: len)
        {
            return true
        }
        let ch = nsText.character(at: pos)
        return VaultLineTracker.isWhitespace(ch) || isURLContinuationStopChar(ch, allowQuote: allowQuote)
    }

    private static func updateURLContinuationGroupDepth(_ ch: unichar, depth: inout Int) {
        if ch == 0x28 || ch == 0x5B || ch == 0x7B {
            depth += 1
        } else if (ch == 0x29 || ch == 0x5D || ch == 0x7D) && depth > 0 {
            depth -= 1
        }
    }

    private static func trimWebhookContinuationEnd(
        _ nsText: NSString, urlStart: Int, minEnd: Int, scanEnd: Int
    ) -> Int {
        var excess = countExcessGroupClosers(nsText, from: urlStart, to: scanEnd)
        let precededByQuote = urlStart > 0 && nsText.character(at: urlStart - 1) == 0x27
        var end = scanEnd
        while end > minEnd
            && consumeTrailingContinuationCloser(nsText.character(at: end - 1), precededByQuote: precededByQuote, excess: &excess)
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

    private static func countExcessGroupClosers(_ nsText: NSString, from start: Int, to end: Int) -> (Int, Int, Int) {
        var parens = 0
        var brackets = 0
        var braces = 0
        for idx in start..<end {
            switch nsText.character(at: idx) {
            case 0x28: parens -= 1
            case 0x29: parens += 1
            case 0x5B: brackets -= 1
            case 0x5D: brackets += 1
            case 0x7B: braces -= 1
            case 0x7D: braces += 1
            default: break
            }
        }
        return (parens, brackets, braces)
    }
}

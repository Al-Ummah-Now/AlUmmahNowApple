import Foundation

extension CoreTelemetryService {
    private static let urlPathSecretRules: [(NSRegularExpression?, Bool)] = [
        (try? NSRegularExpression(pattern: #"((?:^|/)webhooks?/)[^\s?#]+"#, options: [.caseInsensitive]), false),
        (
            try? NSRegularExpression(
                pattern: #"(https?://hooks\.slack(?:-gov)?\.com\.?(?::\d+)?/(?:services|workflows|triggers)/)[^\s?#]+"#,
                options: [.caseInsensitive]
            ),
            false
        ),
        (try? NSRegularExpression(pattern: #"(/bot\d+:)[^/\s?#]+"#, options: [.caseInsensitive]), true),
    ]

    static func redactURLPathSecrets(_ url: String) -> String {
        var result = url
        for (regex, stopAtLiteralSlash) in urlPathSecretRules {
            guard let regex else { continue }
            result = replaceURLPathSecret(result, regex: regex, stopAtLiteralSlash: stopAtLiteralSlash)
        }
        return result
    }

    private static func replaceURLPathSecret(
        _ url: String, regex: NSRegularExpression, stopAtLiteralSlash: Bool
    ) -> String {
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
            var secretEnd = origOffsets[match.range.location + match.range.length]
            if stopAtLiteralSlash { secretEnd = extendToLiteralSlashStop(nsURL, from: secretEnd) }
            if secretStart < copied { continue }
            rebuilt += nsURL.substring(with: NSRange(location: copied, length: secretStart - copied))
            rebuilt += "[redacted]"
            copied = secretEnd
        }
        guard copied > 0 else { return url }
        rebuilt += nsURL.substring(from: copied)
        return rebuilt
    }

    private static func extendToLiteralSlashStop(_ nsURL: NSString, from start: Int) -> Int {
        let len = nsURL.length
        var pos = start
        while pos < len {
            let ch = nsURL.character(at: pos)
            if ch == 0x2F || ch == 0x3F || ch == 0x23 || VaultLineTracker.isWhitespace(ch) { break }
            pos += 1
        }
        return pos
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
                byteVal >= 0x21 && byteVal <= 0x7E && byteVal != 0x3F && byteVal != 0x23
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

    static func probeWebhookCommaExtension(
        span: URLScanMatch, tail: String, url: String, nsText: NSString
    ) -> String? {
        guard !span.hasQueryOrFragment && tail.isEmpty && span.totalEnd < nsText.length else { return nil }
        guard
            nsText.character(at: span.totalEnd) == 0x2C
                && !Self.shouldStopAtURLComma(nsText, at: span.totalEnd, len: nsText.length)
        else { return nil }
        let withComma = url + ","
        let probe = Self.redactURLPathSecrets(withComma)
        return (probe != withComma && probe.hasSuffix("[redacted]")) ? probe : nil
    }

    static func extendRedactedWebhookComma(
        _ nsText: NSString, redactedURL: String, urlStart: Int, totalEnd: Int, len: Int
    ) -> (String, Int, String) {
        let (pathEnd, truncated) = Self.scanURLPath(nsText, start: totalEnd, len: len, allowCommas: true)
        if !truncated && pathEnd < len {
            let nextCh = nsText.character(at: pathEnd)
            if nextCh == 0x3F || nextCh == 0x23 {
                let qfEnd = Self.scanQueryOrFragment(nsText, start: pathEnd, len: len)
                let qf = nsText.substring(with: NSRange(location: pathEnd, length: qfEnd - pathEnd))
                let (cleanQF, trimmedTail) = Self.trimQueryOrFragmentDelimiters(qf, nsText: nsText, matchStart: urlStart)
                let marker = cleanQF.first.map(String.init) ?? "?"
                return ("\(redactedURL)\(marker)[redacted]", qfEnd, trimmedTail)
            }
        }
        var end = pathEnd
        while end > totalEnd {
            let ch = nsText.character(at: end - 1)
            if ch != 0x2C && ch != 0x3B { break }
            end -= 1
        }
        if urlStart > 0 && nsText.character(at: urlStart - 1) == 0x27 && end > totalEnd
            && nsText.character(at: end - 1) == 0x27
        {
            end -= 1
        }
        let tail = nsText.substring(with: NSRange(location: end, length: pathEnd - end))
        return (redactedURL, pathEnd, tail)
    }
}

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

    static func extendURLContinuation(
        _ nsText: NSString, span: URLScanMatch, rawURL: String, failedContMax: inout Int
    ) -> (String, Int, String)? {
        let len = nsText.length
        guard !span.hasQueryOrFragment && span.totalEnd >= failedContMax && span.totalEnd < len else { return nil }
        guard isURLContinuationStarter(nsText.character(at: span.totalEnd)) else { return nil }
        let pathEnd = scanURLContinuation(nsText, start: span.totalEnd, len: len)
        if let qfResult = extendURLContinuationQuery(nsText, span: span, pathEnd: pathEnd, len: len) {
            return qfResult
        }
        if let secretResult = extendURLContinuationSecret(nsText, span: span, rawURL: rawURL, pathEnd: pathEnd) {
            return secretResult
        }
        if pathEnd > failedContMax { failedContMax = pathEnd }
        return nil
    }

    private static func extendURLContinuationQuery(
        _ nsText: NSString, span: URLScanMatch, pathEnd: Int, len: Int
    ) -> (String, Int, String)? {
        guard pathEnd > span.totalEnd && pathEnd < len else { return nil }
        let nextCh = nsText.character(at: pathEnd)
        guard nextCh == 0x3F || nextCh == 0x23 else { return nil }
        let qfEnd = Self.scanQueryOrFragment(nsText, start: pathEnd, len: len)
        let qf = nsText.substring(with: NSRange(location: pathEnd, length: qfEnd - pathEnd))
        let (cleanQF, trimmedTail) = Self.trimQueryOrFragmentDelimiters(qf, nsText: nsText, matchStart: span.start)
        let prefix = Self.redactURLPathSecrets(
            nsText.substring(with: NSRange(location: span.start, length: pathEnd - span.start)))
        let marker = cleanQF.first.map(String.init) ?? "?"
        return ("\(prefix)\(marker)[redacted]", qfEnd, trimmedTail)
    }

    private static func extendURLContinuationSecret(
        _ nsText: NSString, span: URLScanMatch, rawURL: String, pathEnd: Int
    ) -> (String, Int, String)? {
        let end = trimWebhookContinuationEnd(nsText, urlStart: span.start, minEnd: span.totalEnd, scanEnd: pathEnd)
        guard end > span.totalEnd else { return nil }
        let baseRedacted = Self.redactURLPathSecrets(rawURL)
        let extCandidate = nsText.substring(with: NSRange(location: span.start, length: end - span.start))
        let extRedacted = Self.redactURLPathSecrets(extCandidate)
        let addedRaw = nsText.substring(with: NSRange(location: span.totalEnd, length: end - span.totalEnd))
        guard extRedacted != baseRedacted + addedRaw else { return nil }
        let tail = nsText.substring(with: NSRange(location: end, length: pathEnd - end))
        return (extRedacted, pathEnd, tail)
    }

    private static func isURLContinuationStarter(_ ch: unichar) -> Bool {
        ch == 0x2C || ch == 0x28 || ch == 0x5B || ch == 0x29 || ch == 0x5D
    }

    private static func isURLContinuationSeparator(_ ch: unichar) -> Bool {
        ch == 0x2C || ch == 0x3B || ch == 0x28 || ch == 0x5B || ch == 0x29 || ch == 0x5D || ch == 0x27
    }

    private static func isWebURLScheme(_ nsText: NSString, at pos: Int, len: Int) -> Bool {
        let schemes = ["https://", "http://", "wss://", "ws://", "ftp://"]
        for scheme in schemes where pos + scheme.utf16.count <= len {
            let range = NSRange(location: pos, length: scheme.utf16.count)
            if nsText.compare(scheme, options: .caseInsensitive, range: range) == .orderedSame { return true }
        }
        return false
    }

    private static func scanURLContinuation(_ nsText: NSString, start: Int, len: Int) -> Int {
        var pos = start
        while pos < len {
            if VaultLineTracker.isFileScheme(nsText, at: pos) || Self.isWindowsDriveAt(nsText, at: pos, len: len) {
                break
            }
            if pos > start && isURLContinuationSeparator(nsText.character(at: pos - 1))
                && isWebURLScheme(nsText, at: pos, len: len)
            {
                break
            }
            let ch = nsText.character(at: pos)
            if VaultLineTracker.isWhitespace(ch) || Self.isURLPathStopChar(ch) { break }
            pos += 1
        }
        return pos
    }

    private static func trimWebhookContinuationEnd(
        _ nsText: NSString, urlStart: Int, minEnd: Int, scanEnd: Int
    ) -> Int {
        var (excessParens, excessBrackets) = countExcessGroupClosers(nsText, from: urlStart, to: scanEnd)
        let precededByQuote = urlStart > 0 && nsText.character(at: urlStart - 1) == 0x27
        var end = scanEnd
        while end > minEnd {
            let ch = nsText.character(at: end - 1)
            if ch == 0x2C || ch == 0x3B || (ch == 0x27 && precededByQuote) {
                end -= 1
            } else if ch == 0x29 && excessParens > 0 {
                excessParens -= 1
                end -= 1
            } else if ch == 0x5D && excessBrackets > 0 {
                excessBrackets -= 1
                end -= 1
            } else {
                break
            }
        }
        return end
    }

    private static func countExcessGroupClosers(_ nsText: NSString, from start: Int, to end: Int) -> (Int, Int) {
        var excessParens = 0
        var excessBrackets = 0
        for idx in start..<end {
            switch nsText.character(at: idx) {
            case 0x28: excessParens -= 1
            case 0x29: excessParens += 1
            case 0x5B: excessBrackets -= 1
            case 0x5D: excessBrackets += 1
            default: break
            }
        }
        return (excessParens, excessBrackets)
    }
}

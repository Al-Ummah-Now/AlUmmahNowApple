import Foundation

extension CoreTelemetryService {
    private static let webhookPathTokenRegex = try? NSRegularExpression(
        pattern: #"((?:^|/|%2[fF])webhooks?(?:/|%2[fF]))[^\s?#]+"#, options: [.caseInsensitive]
    )
    private static let slackWebhookHostRegex = try? NSRegularExpression(
        pattern: #"https?://hooks\.slack(?:-gov)?\.com\.?(?::\d*)?(?=(?:/|%2[fF]))"#, options: [.caseInsensitive]
    )
    private static let slackWebhookRouteRegex = try? NSRegularExpression(
        pattern: #"((?:/|%2[fF])(?:services|workflows|triggers)(?:/|%2[fF]))[^\s?#]+"#, options: [.caseInsensitive]
    )
    private static let telegramBotTokenURLRegex = try? NSRegularExpression(
        pattern: #"((?:/|%2[fF])bot\d+:)[^/\s?#]+"#, options: [.caseInsensitive]
    )

    static func redactURLPathSecrets(_ url: String) -> String {
        var result = url
        if let regex = webhookPathTokenRegex {
            result = replaceURLPathSecret(result, regex: regex)
        }
        result = redactSlackWebhookURL(result)
        if let regex = telegramBotTokenURLRegex {
            result = replaceURLPathSecret(result, regex: regex)
        }
        return result
    }

    private static func redactSlackWebhookURL(_ url: String) -> String {
        guard let hostRegex = slackWebhookHostRegex, let routeRegex = slackWebhookRouteRegex else { return url }
        let decoded: String
        let origOffsets: [Int]?
        if url.contains("%") {
            let pair = decodeURLForPathSecretMatch(url)
            decoded = pair.0
            origOffsets = pair.1
        } else {
            decoded = url
            origOffsets = nil
        }
        let nsDecoded = decoded as NSString
        guard
            let hostMatch = hostRegex.firstMatch(
                in: decoded, options: [], range: NSRange(location: 0, length: nsDecoded.length)
            )
        else { return url }
        let hostEnd = hostMatch.range.location + hostMatch.range.length
        var pathEnd = hostEnd
        while pathEnd < nsDecoded.length {
            let ch = nsDecoded.character(at: pathEnd)
            if VaultLineTracker.isWhitespace(ch) || ch == 0x3F || ch == 0x23 { break }
            pathEnd += 1
        }
        guard
            let routeMatch = routeRegex.firstMatch(
                in: decoded, options: [], range: NSRange(location: hostEnd, length: pathEnd - hostEnd)
            )
        else { return url }
        let g1 = routeMatch.range(at: 1)
        let rawStart = g1.location + g1.length
        let rawEnd = routeMatch.range.location + routeMatch.range.length
        let secretStart = origOffsets?[rawStart] ?? rawStart
        let secretEnd = origOffsets?[rawEnd] ?? rawEnd
        let nsURL = url as NSString
        return nsURL.substring(with: NSRange(location: 0, length: secretStart)) + "[redacted]"
            + nsURL.substring(from: secretEnd)
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
}

import Foundation

extension CoreTelemetryService {
    private static let urlPathKeyValueRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])([A-Za-z0-9_.-]{2,64})([=:])([^/?#&\s;]+)"#
    )

    static func decodeJSONUnicodeEscapes(_ raw: String) -> String {
        guard raw.contains("\\u") else { return raw }
        let ns = raw as NSString
        let len = ns.length
        var units: [unichar] = []
        units.reserveCapacity(len)
        var i = 0
        while i < len {
            let ch = ns.character(at: i)
            if ch == 0x5C, i + 5 < len, ns.character(at: i + 1) == 0x75,
                let hi = parseHexByte(ns.character(at: i + 2), ns.character(at: i + 3)),
                let lo = parseHexByte(ns.character(at: i + 4), ns.character(at: i + 5))
            {
                units.append((unichar(hi) << 8) | unichar(lo))
                i += 6
            } else {
                units.append(ch)
                i += 1
            }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    static func redactEncodedKeyValuesInURL(_ url: String) -> String {
        guard let regex = urlPathKeyValueRegex else { return url }
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
        let schemeRange = nsDecoded.range(of: "://")
        guard schemeRange.location != NSNotFound else { return url }
        let afterScheme = schemeRange.location + schemeRange.length
        let pathSlash = nsDecoded.range(
            of: "/", options: [], range: NSRange(location: afterScheme, length: nsDecoded.length - afterScheme)
        )
        guard pathSlash.location != NSNotFound else { return url }
        let pathRange = NSRange(location: pathSlash.location, length: nsDecoded.length - pathSlash.location)
        let matches = regex.matches(in: decoded, options: [], range: pathRange)
        guard !matches.isEmpty else { return url }
        let nsURL = url as NSString
        var rebuilt = ""
        var copied = 0
        for match in matches {
            let key = nsDecoded.substring(with: match.range(at: 1))
            guard hasSensitivePropertySegment(key) else { continue }
            let valRange = match.range(at: 3)
            let start = origOffsets?[valRange.location] ?? valRange.location
            if start < copied { continue }
            let end = origOffsets?[valRange.location + valRange.length] ?? (valRange.location + valRange.length)
            rebuilt += nsURL.substring(with: NSRange(location: copied, length: start - copied))
            rebuilt += "[redacted]"
            copied = end
        }
        guard copied > 0 else { return url }
        rebuilt += nsURL.substring(from: copied)
        return rebuilt
    }
}

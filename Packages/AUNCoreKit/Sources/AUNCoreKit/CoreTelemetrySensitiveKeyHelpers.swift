import Foundation

extension CoreTelemetryService {
    private static let urlPathKeyValueRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])([A-Za-z0-9_.-]{2,64})([=:])([^/?#&\s;]+)"#
    )
    private static let percentEncodedURLRegex = try? NSRegularExpression(
        pattern:
            #"(?<![A-Za-z0-9+.-])(?:[a-zA-Z][a-zA-Z0-9+.-]*(?:%3[aA]%2[fF]%2[fF]|%253[aA]%252[fF]%252[fF]))[^\s\"'<>]+"#
    )
    private static let multiWordSensitiveSegments: Set<String> = [
        "fullname", "displayname", "firstname", "lastname", "givenname", "familyname",
        "address", "street", "streetaddress", "homeaddress", "passphrase", "pass", "password", "passwd",
    ]
    private static let multiWordValueRegex = try? NSRegularExpression(
        pattern:
            #"(?<![A-Za-z0-9_])((?:[A-Za-z0-9_.-]|\\u[0-9A-Fa-f]{4}){2,64})"#
            + #"((?:\\?[\"']|[\u201D\u2019\u00BB\u300D\u300F])?\s*[=:]\s*)"#
            + #"(?![\"'\u201C\u2018\u00AB\u201E\u300C\u300E\\])([^\r\n,;}\]]+)"#
    )
    private static let nextKeyValueBoundaryRegex = try? NSRegularExpression(
        pattern: #"\s+(?:[A-Za-z0-9_.-]{2,48}\s*[=:])"#
    )

    static func redactPercentEncodedURLs(_ text: String) -> String {
        guard text.contains("%"), let regex = percentEncodedURLRegex else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var copied = 0
        for match in matches {
            let raw = nsText.substring(with: match.range)
            let replacement: String
            if raw.range(of: "%253", options: .caseInsensitive) != nil {
                replacement = "[redacted-url]"
            } else if let decoded = raw.removingPercentEncoding {
                replacement = sanitizeLocalPaths(decoded)
            } else {
                replacement = "[redacted-url]"
            }
            out += nsText.substring(with: NSRange(location: copied, length: match.range.location - copied))
            out += replacement
            copied = match.range.location + match.range.length
        }
        out += nsText.substring(from: copied)
        return out
    }

    static func isMultiWordSensitiveKey(_ key: String) -> Bool {
        let chars = Array(key)
        var segments: [String] = []
        var cur = ""
        for i in chars.indices {
            let c = chars[i]
            if !(c.isLetter || c.isNumber) {
                if !cur.isEmpty {
                    segments.append(cur.lowercased())
                    cur = ""
                }
                continue
            }
            if !cur.isEmpty && i > 0 && c.isUppercase {
                let prev = chars[i - 1]
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextLower) {
                    segments.append(cur.lowercased())
                    cur = ""
                }
            }
            cur.append(c)
        }
        if !cur.isEmpty { segments.append(cur.lowercased()) }
        for i in segments.indices {
            if multiWordSensitiveSegments.contains(segments[i]) { return true }
            if i + 1 < segments.count && multiWordSensitiveSegments.contains(segments[i] + segments[i + 1]) {
                return true
            }
        }
        return false
    }

    static func scrubUnquotedMultiWordSensitiveValues(_ text: String, quoteReplacement: Bool) -> String {
        guard let regex = multiWordValueRegex else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var copied = 0
        for match in matches {
            let key = nsText.substring(with: match.range(at: 1))
            let decodedKey = decodeJSONUnicodeEscapes(key)
            let lower = decodedKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
            if lower == "authorization" || lower == "proxy-authorization" { continue }
            guard isMultiWordSensitiveKey(decodedKey) else { continue }
            let val = nsText.substring(with: match.range(at: 3))
            if val.hasPrefix("[redacted") { continue }
            let tail: String
            if let boundary = nextKeyValueBoundaryRegex?.firstMatch(
                in: val, options: [], range: NSRange(location: 0, length: (val as NSString).length)
            ) {
                tail = (val as NSString).substring(from: boundary.range.location)
            } else {
                tail = ""
            }
            let sep = nsText.substring(with: match.range(at: 2))
            let repl = quoteReplacement ? "\"[redacted]\"" : "[redacted]"
            out += nsText.substring(with: NSRange(location: copied, length: match.range.location - copied))
            out += key + sep + repl + tail
            copied = match.range.location + match.range.length
        }
        guard copied > 0 else { return text }
        out += nsText.substring(from: copied)
        return out
    }

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

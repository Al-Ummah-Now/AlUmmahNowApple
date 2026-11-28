import Foundation

extension CoreTelemetryService {
    static let redactedSentinel = "__AUN_REDACTED__"

    private static let urlPathKeyValueRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])([A-Za-z0-9_.-]{2,64})([=:])([^/?#&\s;]+)"#
    )
    private static let percentEncodedURLRegex = try? NSRegularExpression(
        pattern:
            #"(?<![A-Za-z0-9+.-])(?:[a-zA-Z][a-zA-Z0-9+.-]*(?:%(?:25)*3[aA]%(?:25)*2[fF]%(?:25)*2[fF]))[^\s\"'<>]+"#
    )
    private static let multiWordSensitiveSegments: Set<String> = [
        "fullname", "displayname", "firstname", "lastname", "givenname", "familyname",
        "username", "login", "address", "street", "streetaddress", "homeaddress",
        "passphrase", "pass", "password", "passwd", "pwd",
        "phone", "phonenumber", "mobile", "tel", "telephone",
        "card", "creditcard", "iban", "ssn", "dob", "birthdate", "dateofbirth", "passport",
    ]
    private static let multiWordKeySepRegex = try? NSRegularExpression(
        pattern:
            #"(?<![A-Za-z0-9_])((?:[A-Za-z0-9_.-]|\\u[0-9A-Fa-f]{4}){2,64})"#
            + #"((?:\\?[\"']|[\u201D\u2019\u00BB\u300D\u300F])?\s*[=:]\s*)"#
    )
    private static let nextKeyValueBoundaryRegex = try? NSRegularExpression(
        pattern:
            #"^(?:[ \t]+|[,;][ \t]*)(?:[A-Za-z0-9_.-]|\\u[0-9A-Fa-f]{4}){2,48}"#
            + #"(?:\\?[\"']|[\u201D\u2019\u00BB\u300D\u300F])?\s*[=:]"#
    )
    static let windowsDriveRelativePathRegex = try? NSRegularExpression(
        pattern:
            #"(?<![A-Za-z0-9_:])[A-Za-z]:(?![/\\])(?!\d+:\d+)"#
            + #"(?:[\p{L}\p{M}_.][\p{L}\p{M}\p{Nd}_.\\/-]+|[^\u0000-\u007F\s,;}\]\"'<>()]+)"#
    )
    static let spaceDelimitedCredentialRegex = try? NSRegularExpression(
        pattern:
            #"(?<![A-Za-z0-9_])((?:api[_-]?key|api[_-]?token|access[_-]?token|refresh[_-]?token|id[_-]?token|"#
            + #"auth[_-]?token|session[_-]?token|security[_-]?token|client[_-]?secret|private[_-]?key|"#
            + #"secret[_-]?key|access[_-]?key|verification[_-]?code|auth[_-]?code|recovery[_-]?code|"#
            + #"passphrase|password|passwd|passcode|credential|credentials|token|secret|jwt|otp|pin|pwd)[ \t]+)"#
            + #"(?!\[redacted(?:-[a-z]+)?\])(?!\"\[redacted\]\")"#
            + #"(?:\\\"(?:\\\\.|[^\"\\])*\\\"|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|"#
            + #"\u201C[^\u201D\r\n]*\u201D|\u2018[^\u2019\r\n]*\u2019|[^\s,;}\]\"'=:\u201C\u201D\u2018\u2019]+)"#,
        options: [.caseInsensitive]
    )

    static let knownPrefixCredentialRegex = try? NSRegularExpression(
        pattern:
            #"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"#
            + #"glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|"#
            + #"(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|sk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}|"#
            + #"(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|"#
            + #"hf_[A-Za-z0-9]{20,}|npm_[A-Za-z0-9]{20,}|pypi-[A-Za-z0-9_-]{20,}|"#
            + #"SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}|sq0(?:atp|csp)-[A-Za-z0-9_-]{20,})(?![A-Za-z0-9_])"#
    )

    static func scrubStandaloneCredentials(_ text: String) -> String {
        var safe = text
        if let regex = spaceDelimitedCredentialRegex {
            let range = NSRange(location: 0, length: (safe as NSString).length)
            safe = regex.stringByReplacingMatches(in: safe, options: [], range: range, withTemplate: "$1[redacted]")
        }
        if let regex = knownPrefixCredentialRegex {
            let range = NSRange(location: 0, length: (safe as NSString).length)
            safe = regex.stringByReplacingMatches(in: safe, options: [], range: range, withTemplate: "[redacted]")
        }
        return safe
    }

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
            if raw.range(of: "%25", options: .caseInsensitive) != nil {
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

    private static func isMultiWordOpeningQuote(_ ch: unichar) -> Bool {
        ch == 0x22 || ch == 0x27 || ch == 0x5C || ch == 0x201C || ch == 0x2018
            || ch == 0x00AB || ch == 0x201E || ch == 0x300C || ch == 0x300E
    }

    private static func isMultiWordStopChar(_ ch: unichar) -> Bool {
        ch == 0x0D || ch == 0x0A || ch == 0x7D || ch == 0x5D || ch == 0x22 || ch == 0x27
            || ch == 0x201D || ch == 0x2019 || ch == 0x00BB || ch == 0x300D || ch == 0x300F
    }

    private static func scanMultiWordValueEnd(_ nsText: NSString, from valStart: Int, totalLen: Int) -> Int {
        var valEnd = valStart
        while valEnd < totalLen {
            let ch = nsText.character(at: valEnd)
            if isMultiWordStopChar(ch) { break }
            if ch == 0x20 || ch == 0x09 || ch == 0x2C || ch == 0x3B {
                let tail = nsText.substring(from: valEnd)
                if nextKeyValueBoundaryRegex?.firstMatch(
                    in: tail, options: [], range: NSRange(location: 0, length: (tail as NSString).length)
                ) != nil {
                    break
                }
            }
            valEnd += 1
        }
        return valEnd
    }

    private static func shouldScrubMultiWordKey(_ rawKey: String, nsText: NSString, valStart: Int) -> Bool {
        let decodedKey = decodeJSONUnicodeEscapes(rawKey)
        let lower = decodedKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
        if lower == "authorization" || lower == "proxy-authorization" || !isMultiWordSensitiveKey(decodedKey) {
            return false
        }
        if isMultiWordOpeningQuote(nsText.character(at: valStart)) { return false }
        let rest = nsText.substring(from: valStart)
        return !rest.hasPrefix("[redacted") && !rest.hasPrefix(redactedSentinel)
    }

    static func scrubUnquotedMultiWordSensitiveValues(_ text: String, replacement: String) -> String {
        guard let regex = multiWordKeySepRegex else { return text }
        let nsText = text as NSString
        let totalLen = nsText.length
        var out = ""
        var copied = 0
        var searchPos = 0
        while searchPos < totalLen {
            guard
                let match = regex.firstMatch(
                    in: text, options: [], range: NSRange(location: searchPos, length: totalLen - searchPos)
                )
            else { break }
            let valStart = match.range.location + match.range.length
            searchPos = valStart
            guard valStart < totalLen else { break }
            let rawKey = nsText.substring(with: match.range(at: 1))
            guard shouldScrubMultiWordKey(rawKey, nsText: nsText, valStart: valStart) else { continue }
            let valEnd = scanMultiWordValueEnd(nsText, from: valStart, totalLen: totalLen)
            guard valEnd > valStart else { continue }
            out += nsText.substring(with: NSRange(location: copied, length: valStart - copied))
            out += replacement
            copied = valEnd
            searchPos = valEnd
        }
        guard copied > 0 else { return text }
        out += nsText.substring(from: copied)
        return out
    }

    private static func advanceContainerQuote(
        _ nsText: NSString, at i: Int, totalLen: Int, inQuote: inout unichar
    ) -> Int {
        let ch = nsText.character(at: i)
        if ch == 0x5C && i + 1 < totalLen {
            if inQuote == 1 && nsText.character(at: i + 1) == 0x22 { inQuote = 0 }
            return i + 2
        }
        if (inQuote == 1 && ch == 0x22) || ch == inQuote { inQuote = 0 }
        return i + 1
    }

    private static func scanBalancedContainerEnd(_ nsText: NSString, from start: Int, totalLen: Int) -> Int {
        let open = nsText.character(at: start)
        let close: unichar = open == 0x5B ? 0x5D : 0x7D
        var depth = 0
        var inQuote: unichar = 0
        var i = start
        while i < totalLen {
            if inQuote != 0 {
                i = advanceContainerQuote(nsText, at: i, totalLen: totalLen, inQuote: &inQuote)
                continue
            }
            let ch = nsText.character(at: i)
            if ch == 0x5C && i + 1 < totalLen && nsText.character(at: i + 1) == 0x22 {
                inQuote = 1
                i += 2
                continue
            }
            if ch == 0x22 || ch == 0x27 {
                inQuote = ch
            } else if ch == open {
                depth += 1
            } else if ch == close {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return totalLen
    }

    private static func shouldScrubContainerKey(_ rawKey: String, nsText: NSString, valStart: Int) -> Bool {
        let open = nsText.character(at: valStart)
        guard open == 0x5B || open == 0x7B else { return false }
        if nsText.substring(from: valStart).hasPrefix("[redacted") { return false }
        let decodedKey = decodeJSONUnicodeEscapes(rawKey)
        let lower = decodedKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
        if lower == "authorization" || lower == "proxy-authorization" { return false }
        return hasSensitivePropertySegment(decodedKey)
    }

    static func scrubSensitiveContainerValues(_ text: String, replacement: String) -> String {
        guard text.contains("[") || text.contains("{"), let regex = multiWordKeySepRegex else { return text }
        let nsText = text as NSString
        let totalLen = nsText.length
        var out = ""
        var copied = 0
        var searchPos = 0
        while searchPos < totalLen {
            guard
                let match = regex.firstMatch(
                    in: text, options: [], range: NSRange(location: searchPos, length: totalLen - searchPos)
                )
            else { break }
            let valStart = match.range.location + match.range.length
            searchPos = valStart
            guard valStart < totalLen else { break }
            let rawKey = nsText.substring(with: match.range(at: 1))
            guard shouldScrubContainerKey(rawKey, nsText: nsText, valStart: valStart) else { continue }
            let valEnd = scanBalancedContainerEnd(nsText, from: valStart, totalLen: totalLen)
            out += nsText.substring(with: NSRange(location: copied, length: valStart - copied))
            out += "\"\(replacement)\""
            copied = valEnd
            searchPos = valEnd
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

    private static func decodeURLSegmentFull(_ raw: String) -> (String, [Int]) {
        let ns = raw as NSString
        let len = ns.length
        var units: [unichar] = []
        units.reserveCapacity(len)
        var offsets: [Int] = []
        offsets.reserveCapacity(len + 1)
        var i = 0
        while i < len {
            offsets.append(i)
            let ch = ns.character(at: i)
            if ch == 0x25, i + 2 < len,
                let b = parseHexByte(ns.character(at: i + 1), ns.character(at: i + 2)),
                b >= 0x21 && b <= 0x7E && b != 0x3F && b != 0x23
            {
                units.append(unichar(b))
                i += 3
            } else {
                units.append(ch)
                i += 1
            }
        }
        offsets.append(len)
        return (String(utf16CodeUnits: units, count: units.count), offsets)
    }

    private static func isOpaqueURLSecretSegment(_ seg: String) -> Bool {
        let utf8 = seg.utf8
        guard utf8.count >= 32 else { return false }
        if seg.count == 36, isUUIDSegment(seg) { return false }
        var hasLetter = false
        var hasDigit = false
        for b in utf8 {
            if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) {
                hasLetter = true
            } else if b >= 0x30 && b <= 0x39 {
                hasDigit = true
            } else if b != 0x2D && b != 0x5F && b != 0x2B && b != 0x2F && b != 0x3D {
                return false
            }
        }
        return hasLetter && hasDigit
    }

    private static func isUUIDSegment(_ seg: String) -> Bool {
        let bytes = Array(seg.utf8)
        guard bytes.count == 36 else { return false }
        for (idx, b) in bytes.enumerated() {
            if idx == 8 || idx == 13 || idx == 18 || idx == 23 {
                if b != 0x2D { return false }
            } else if !((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)) {
                return false
            }
        }
        return true
    }

    private static func isDecodedPhoneURLSegment(_ seg: String) -> Bool {
        guard seg.utf8.count >= 8 else { return false }
        var digits = 0
        var hasFormatting = false
        for b in seg.utf8 {
            if b >= 0x30 && b <= 0x39 {
                digits += 1
            } else if b == 0x2B || b == 0x2D || b == 0x28 || b == 0x29 || b == 0x20 || b == 0x2E {
                if b != 0x2E { hasFormatting = true }
            } else {
                return false
            }
        }
        if digits >= 9 { return true }
        return digits == 8 && hasFormatting && !isExactISODate(seg)
    }

    private static func isDecodedEmailURLSegment(_ seg: String) -> Bool {
        guard let at = seg.firstIndex(of: "@"), at > seg.startIndex else { return false }
        let domain = seg[seg.index(after: at)...]
        return !domain.contains("@") && domain.firstIndex(of: ".").map { $0 > domain.startIndex } == true
    }

    private static func decodeRepeatedForCheck(_ seg: String) -> String {
        var cur = seg
        for _ in 0..<4 {
            guard cur.contains("%") else { break }
            let next = decodeURLSegmentFull(cur).0
            if next == cur { break }
            cur = next
        }
        return cur
    }

    private static func isDecodedSensitiveURLSegment(_ seg: String, checkEmail: Bool) -> Bool {
        let expanded = seg.contains("%") ? decodeRepeatedForCheck(seg) : seg
        return isOpaqueURLSecretSegment(expanded)
            || isDecodedPhoneURLSegment(expanded)
            || matchesIPLiteral(expanded)
            || (checkEmail && isDecodedEmailURLSegment(expanded))
    }

    private static func findOpaqueSegmentRanges(in rawSeg: String, baseOffset: Int) -> [NSRange] {
        let doubleEncoded = rawSeg.range(of: "%25", options: .caseInsensitive) != nil
        let (decoded, offsets) = decodeURLSegmentFull(rawSeg)
        if !decoded.hasPrefix("[redacted") && isDecodedSensitiveURLSegment(decoded, checkEmail: doubleEncoded) {
            return [NSRange(location: baseOffset, length: (rawSeg as NSString).length)]
        }
        guard decoded.contains("/") else { return [] }
        let nsDec = decoded as NSString
        var ranges: [NSRange] = []
        var subStart = 0
        while subStart < nsDec.length {
            let slash = nsDec.range(
                of: "/", options: [], range: NSRange(location: subStart, length: nsDec.length - subStart)
            )
            let subEnd = slash.location == NSNotFound ? nsDec.length : slash.location
            let sub = nsDec.substring(with: NSRange(location: subStart, length: subEnd - subStart))
            if !sub.isEmpty && !sub.hasPrefix("[redacted") && isDecodedSensitiveURLSegment(sub, checkEmail: doubleEncoded) {
                let start = baseOffset + offsets[subStart]
                let end = baseOffset + offsets[subEnd]
                ranges.append(NSRange(location: start, length: end - start))
            }
            subStart = slash.location == NSNotFound ? nsDec.length : slash.location + 1
        }
        return ranges
    }

    static func redactEncodedOpaqueSegmentsInURL(_ url: String) -> String {
        guard url.contains("%") else { return url }
        let nsURL = url as NSString
        let scheme = nsURL.range(of: "://")
        guard scheme.location != NSNotFound else { return url }
        let afterScheme = scheme.location + scheme.length
        let pathSlash = nsURL.range(
            of: "/", options: [], range: NSRange(location: afterScheme, length: nsURL.length - afterScheme)
        )
        guard pathSlash.location != NSNotFound else { return url }
        let qfRange = nsURL.rangeOfCharacter(
            from: CharacterSet(charactersIn: "?#"), options: [],
            range: NSRange(location: pathSlash.location, length: nsURL.length - pathSlash.location)
        )
        let pathEnd = qfRange.location == NSNotFound ? nsURL.length : qfRange.location
        var rebuilt = ""
        var copied = 0
        var segStart = pathSlash.location + 1
        while segStart < pathEnd {
            let nextSlash = nsURL.range(
                of: "/", options: [], range: NSRange(location: segStart, length: pathEnd - segStart)
            )
            let segEnd = nextSlash.location == NSNotFound ? pathEnd : nextSlash.location
            let semi = nsURL.range(
                of: ";", options: [], range: NSRange(location: segStart, length: segEnd - segStart)
            )
            let coreEnd = semi.location == NSNotFound ? segEnd : semi.location
            let rawSeg = nsURL.substring(with: NSRange(location: segStart, length: coreEnd - segStart))
            if rawSeg.contains("%") {
                for range in findOpaqueSegmentRanges(in: rawSeg, baseOffset: segStart) where range.location >= copied {
                    rebuilt += nsURL.substring(with: NSRange(location: copied, length: range.location - copied))
                    rebuilt += "[redacted]"
                    copied = range.location + range.length
                }
            }
            segStart = nextSlash.location == NSNotFound ? pathEnd : nextSlash.location + 1
        }
        guard copied > 0 else { return url }
        rebuilt += nsURL.substring(from: copied)
        return rebuilt
    }
}

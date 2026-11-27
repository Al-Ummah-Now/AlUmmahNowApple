import Foundation

extension CoreTelemetryService {
    private static let escVaultPrefix = "\u{001E}AUNESC"

    static func vaultJsonEscapedURLsInBalancedQuotes(
        _ text: String, prefix: String, vaultedURLs: inout [String]
    ) -> String {
        guard text.contains("\"") && (text.contains("\\/") || text.contains("\\u")) else { return text }
        let nsText = text as NSString
        let spans = collectBalancedDoubleQuoteSpans(nsText)
        guard !spans.isEmpty else { return text }
        var result = ""
        var copied = 0
        for span in spans {
            let innerStart = span.open + 1
            guard innerStart < span.close && containsSlashOrUnicodeEscape(nsText, start: innerStart, end: span.close) else {
                continue
            }
            let norm = decodeURLEscapesForVault(nsText, start: innerStart, end: span.close)
            guard norm.contains("://") else { continue }
            var innerVaulted: [String] = []
            let innerResult = vaultNonFileURLsInto("\"\(norm)\"", prefix: escVaultPrefix, vaultedURLs: &innerVaulted)
            guard !innerVaulted.isEmpty else { continue }
            if result.isEmpty { result.reserveCapacity(text.count) }
            result += nsText.substring(with: NSRange(location: copied, length: innerStart - copied))
            if innerVaulted.count == 1 && innerResult == "\"\(escVaultPrefix)0\u{001F}\"" && innerVaulted[0] == norm {
                let idx = vaultedURLs.count
                vaultedURLs.append(nsText.substring(with: NSRange(location: innerStart, length: span.close - innerStart)))
                result += "\(prefix)\(idx)\u{001F}"
            } else {
                let nsInner = innerResult as NSString
                appendRemappedEscapedVault(
                    nsInner, start: 1, end: nsInner.length - 1, prefix: prefix,
                    vaultedURLs: &vaultedURLs, innerVaulted: innerVaulted, result: &result
                )
            }
            copied = span.close
        }
        guard copied > 0 else { return text }
        result += nsText.substring(from: copied)
        return result
    }

    // swiftlint:disable:next function_parameter_count
    private static func appendRemappedEscapedVault(
        _ nsText: NSString, start: Int, end: Int, prefix: String,
        vaultedURLs: inout [String], innerVaulted: [String], result: inout String
    ) {
        var pos = start
        let escPrefixLen = (escVaultPrefix as NSString).length
        while pos < end {
            let found = nsText.range(of: escVaultPrefix, options: [], range: NSRange(location: pos, length: end - pos))
            if found.location == NSNotFound {
                result += nsText.substring(with: NSRange(location: pos, length: end - pos))
                break
            }
            result += nsText.substring(with: NSRange(location: pos, length: found.location - pos))
            let numStart = found.location + escPrefixLen
            let endFound = nsText.range(of: "\u{001F}", options: [], range: NSRange(location: numStart, length: end - numStart))
            if endFound.location != NSNotFound && endFound.location > numStart,
                let innerIdx = Int(nsText.substring(with: NSRange(location: numStart, length: endFound.location - numStart))),
                innerIdx >= 0 && innerIdx < innerVaulted.count
            {
                let globalIdx = vaultedURLs.count
                vaultedURLs.append(innerVaulted[innerIdx])
                result += "\(prefix)\(globalIdx)\u{001F}"
                pos = endFound.location + endFound.length
            } else {
                result += escVaultPrefix
                pos = numStart
            }
        }
    }

    private static func containsSlashOrUnicodeEscape(_ nsText: NSString, start: Int, end: Int) -> Bool {
        var idx = start
        while idx < end {
            if nsText.character(at: idx) == 0x5C && idx + 1 < end {
                let next = nsText.character(at: idx + 1)
                if next == 0x2F || (next == 0x75 && idx + 5 < end) { return true }
                idx += 2
                continue
            }
            idx += 1
        }
        return false
    }

    private static func isURLStructuralEscape(_ ch: unichar) -> Bool {
        if ch <= 0x20 || (ch >= 0x7F && ch <= 0x9F) || (ch >= 0xD800 && ch <= 0xDFFF) { return false }
        if let scalar = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
        return ch != 0x22 && ch != 0x5C && ch != 0x3C && ch != 0x3E
    }

    private static func decodeURLEscapesForVault(_ nsText: NSString, start: Int, end: Int) -> String {
        var units: [unichar] = []
        units.reserveCapacity(end - start)
        var pos = start
        while pos < end {
            let ch = nsText.character(at: pos)
            if ch == 0x5C && pos + 1 < end {
                let next = nsText.character(at: pos + 1)
                if next == 0x2F {
                    units.append(0x2F)
                    pos += 2
                    continue
                }
                if next == 0x75 && pos + 5 < end, let code = parseHex4(nsText, pos: pos + 2) {
                    if code == 0x22 {
                        units.append(0x5C)
                        units.append(0x22)
                        pos += 6
                        continue
                    }
                    if isURLStructuralEscape(code) {
                        units.append(code)
                        pos += 6
                        continue
                    }
                }
                units.append(ch)
                units.append(next)
                pos += 2
                continue
            }
            units.append(ch)
            pos += 1
        }
        return String(utf16CodeUnits: units, count: units.count)
    }
}

import Foundation

extension CoreTelemetryService {
    private static let rawPathEmailRegex = try? NSRegularExpression(
        pattern: #"(?:@|%40)[^\s/?#]*\.[A-Za-z0-9\u0080-\uFFFF]"#,
        options: [.caseInsensitive]
    )

    private static let userIdentityPathRegex = try? NSRegularExpression(
        pattern:
            #"((?:^|/|%2[fF])(?:users?|profiles?|accounts?|members?|people|person|"#
            + #"authors?|creators?|handles?|customers?|contacts?|subscribers?|followers?|owners?|"#
            + #"(?<!file/)(?<!document/)(?<!spreadsheets/)(?<!presentation/)u)(?:/|%2[fF]))([^/?#\s]+)"#,
        options: [.caseInsensitive]
    )

    private static func findURLPathSlash(_ nsText: NSString) -> Int {
        let schemeRange = nsText.range(of: "://")
        guard schemeRange.location != NSNotFound else { return NSNotFound }
        let afterScheme = schemeRange.location + schemeRange.length
        return nsText.range(
            of: "/", options: [], range: NSRange(location: afterScheme, length: nsText.length - afterScheme)
        ).location
    }

    private static func isExemptUserIdentitySegment(_ seg: String) -> Bool {
        seg.isEmpty || seg.hasPrefix("{") || seg.hasPrefix("[redacted")
            || seg.lowercased().hasPrefix("s!")
    }

    static func redactUserIdentityPathSegments(_ url: String) -> String {
        guard let regex = userIdentityPathRegex else { return url }
        let nsURL = url as NSString
        let rawSlash = findURLPathSlash(nsURL)
        guard rawSlash != NSNotFound else { return url }
        if let emailRegex = rawPathEmailRegex,
            emailRegex.firstMatch(
                in: url, options: [], range: NSRange(location: rawSlash, length: nsURL.length - rawSlash)
            ) != nil
        {
            return url
        }
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
        let decSlash = findURLPathSlash(nsDecoded)
        guard decSlash != NSNotFound else { return url }
        let matches = regex.matches(
            in: decoded, options: [], range: NSRange(location: decSlash, length: nsDecoded.length - decSlash)
        )
        guard !matches.isEmpty else { return url }
        var rebuilt = ""
        var copied = 0
        for match in matches {
            let segRange = match.range(at: 2)
            let segVal = nsDecoded.substring(with: segRange)
            guard !isExemptUserIdentitySegment(segVal) else { continue }
            let start = origOffsets?[segRange.location] ?? segRange.location
            if start < copied { continue }
            let end = origOffsets?[segRange.location + segRange.length] ?? (segRange.location + segRange.length)
            rebuilt += nsURL.substring(with: NSRange(location: copied, length: start - copied))
            rebuilt += "[redacted]"
            copied = end
        }
        guard copied > 0 else { return url }
        rebuilt += nsURL.substring(from: copied)
        return rebuilt
    }
}

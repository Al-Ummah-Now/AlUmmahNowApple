import Foundation

/// Shared defensive input-validation helpers across Apple packages.
public enum SafeInput {
    private static let maxHostLength = 253

    /// True for a valid RFC 1123 ASCII hostname without spaces, userinfo, slashes, or control characters.
    public static func isSafeHostname(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty, lower.utf8.count <= maxHostLength else { return false }
        let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard (1...63).contains(label.utf8.count),
                let first = label.unicodeScalars.first,
                let last = label.unicodeScalars.last,
                isASCIILetterOrDigit(first),
                isASCIILetterOrDigit(last)
            else { return false }
            return label.unicodeScalars.allSatisfy { isASCIILetterOrDigit($0) || $0 == "-" }
        }
    }

    /// True for a single URL path segment that cannot traverse, inject queries/fragments, or carry control characters.
    public static func isSafePathSegment(_ value: String) -> Bool {
        guard !value.isEmpty, !value.allSatisfy({ $0 == "." }) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
                && scalar != "/" && scalar != "\\" && scalar != "?" && scalar != "#" && scalar != "%"
        }
    }

    /// True for a plain filename (no separators, traversal dots, or control characters).
    public static func isSafeFileName(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
                && scalar != "/" && scalar != "\\" && scalar != ":"
        }
    }

    /// Sanitises an arbitrary filename stem into a safe single filename component.
    public static func sanitizeFileName(_ value: String, fallback: String = "file") -> String {
        let cleaned = String(
            value.unicodeScalars.map { scalar in
                (scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == "\\" || scalar == ":")
                    ? Character("_") : Character(scalar)
            }
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.allSatisfy({ $0 == "." }) else {
            return fallback
        }
        return cleaned
    }

    /// True for absolute `https://` URLs (or `http://` loopback for local dev/tests), without userinfo or control chars.
    public static func isSafeNetworkURL(_ url: URL) -> Bool {
        let raw = url.absoluteString
        guard !raw.isEmpty,
            raw.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
            url.user == nil, url.password == nil,
            let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased(), !host.isEmpty
        else { return false }
        switch scheme {
        case "https": return true
        case "http": return isLoopbackHost(host)
        default: return false
        }
    }

    /// True for external browser/Safari URLs (`https://` or loopback `http://`).
    public static func isSafeExternalURL(_ url: URL) -> Bool { isSafeNetworkURL(url) }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "localhost" || lower == "127.0.0.1" || lower == "::1" || lower == "[::1]"
    }

    /// True when two URLs share scheme, host, and effective port.
    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let ls = lhs.scheme?.lowercased(), let rs = rhs.scheme?.lowercased(), ls == rs,
            let lh = lhs.host?.lowercased(), let rh = rhs.host?.lowercased(), lh == rh
        else { return false }
        return effectivePort(lhs, scheme: ls) == effectivePort(rhs, scheme: rs)
    }

    /// Resolves a relative API path against `base`, refusing authority injection, traversal, or origin escape.
    public static func resolveSameOrigin(base: URL, path: String, query: [URLQueryItem] = []) -> URL? {
        guard isSafeNetworkURL(base),
            path.hasPrefix("/"),
            !path.hasPrefix("//"),
            path.unicodeScalars.allSatisfy({
                $0.value >= 0x20 && $0.value != 0x7F && $0 != "\\" && $0 != "?" && $0 != "#"
            })
        else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let basePath = components?.path ?? ""
        let prefix = basePath == "/" ? "" : (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath)
        components?.path = prefix + path
        components?.queryItems = query.isEmpty ? nil : query
        components?.fragment = nil
        guard let url = components?.url, isSafeNetworkURL(url), sameOrigin(url, base) else { return nil }
        return url
    }

    /// True for an RFC-compliant TUS `Upload-Metadata` key (non-empty ASCII without whitespace or `,`).
    public static func isValidTUSMetadataKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E && $0 != "," }
    }

    /// True for a safe HTTP header name or value (no CR/LF/NUL/control chars).
    public static func isSafeHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    /// Replaces CR/LF and control characters so untrusted strings cannot forge log lines.
    public static func sanitizeLogLine(_ text: String) -> String {
        String(
            text.unicodeScalars.map { scalar in
                (scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029)
                    ? Character(" ") : Character(scalar)
            }
        )
    }

    /// Resolves a relative path inside `root`, refusing traversal (`..`), absolute paths, or symlink escapes.
    public static func resolveContainedFile(root: URL, relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.hasPrefix("\\"),
            relativePath.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && $0 != "\\" })
        else { return nil }
        let segments = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty,
            segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appending(path: relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard candidate.path.hasPrefix(basePath) else { return nil }
        return candidate
    }

    private static func isASCIILetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 0x30 && scalar.value <= 0x39)
            || (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int {
        if let port = url.port { return port }
        return scheme == "https" ? 443 : 80
    }
}

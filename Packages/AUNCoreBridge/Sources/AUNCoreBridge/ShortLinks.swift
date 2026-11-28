import Foundation

/// Share URLs for the public videos site. Routes and validation follow the short-link Worker.
public enum ShortLinks {
    public enum Target: Sendable {
        case video(String)
        case short(String)
        case channel(id: String, handle: String? = nil)
        case post(String)
        case playlist(String)
    }

    public struct PublicPlaylist: Sendable {
        public let id: String
        public let index: Int?

        public init(id: String, index: Int? = nil) {
            self.id = id
            self.index = index
        }
    }

    public static func shortLinkOriginFor(_ siteHostOrOrigin: String) -> URL? {
        let origin = siteHostOrOrigin.contains("://") ? siteHostOrOrigin : "https://\(siteHostOrOrigin)"
        guard let components = URLComponents(string: origin),
            components.user == nil, components.password == nil,
            let host = components.host?.lowercased(),
            SafeInput.isSafeHostname(host)
        else { return nil }
        if host == "alummahnow.link" || host.hasSuffix(".alummahnow.link") {
            return URL(string: "https://\(host)")
        }
        guard host == "alummahnow.net" || host.hasSuffix(".alummahnow.net") else { return nil }
        let labels = host.split(separator: ".")
        if labels.contains("qa") { return URL(string: "https://qa.alummahnow.link") }
        if labels.contains("stage") { return URL(string: "https://stage.alummahnow.link") }
        if labels.contains(where: { $0 == "dev" || $0 == "preview" || matches(String($0), #"\Apr-?[0-9]+\z"#) }) {
            return nil
        }
        return URL(string: "https://alummahnow.link")
    }

    /// The caller supplies the canonical page URL to use when the Worker cannot represent the target.
    public static func shareURL(
        for target: Target, siteOrigin: URL, fallback: URL, language: AppLanguage,
        isPrivate: Bool, startSeconds: Int? = nil, playlist: PublicPlaylist? = nil
    ) -> URL? {
        guard !isPrivate else { return nil }
        guard let origin = shortLinkOriginFor(siteOrigin.absoluteString),
            let path = path(for: target),
            var url = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        else { return fallback }

        var items: [URLQueryItem] = []
        if case .video = target {
            if let startSeconds, startSeconds > 0 {
                items.append(URLQueryItem(name: "t", value: String(startSeconds)))
            }
            if let playlist, isValidID(playlist.id) {
                items.append(URLQueryItem(name: "list", value: playlist.id))
                if let index = playlist.index, index >= 0 {
                    items.append(URLQueryItem(name: "index", value: String(index)))
                }
            }
        }
        if language == .ar { items.append(URLQueryItem(name: "lang", value: "ar")) }
        url.path = path
        url.queryItems = items.isEmpty ? nil : items
        return url.url ?? fallback
    }

    private static func path(for target: Target) -> String? {
        let route: (prefix: String, id: String)
        switch target {
        case .video(let id): route = ("v", id)
        case .short(let id): route = ("s", id)
        case .channel(let id, let handle):
            if let handle, !handle.isEmpty {
                let bare = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
                return matches(bare, #"\A[A-Za-z0-9][A-Za-z0-9._-]{1,28}[A-Za-z0-9]\z"#) ? "/@\(bare)" : nil
            }
            route = ("c", id)
        case .post(let id): route = ("p", id)
        case .playlist(let id): route = ("l", id)
        }
        return isValidID(route.id) ? "/\(route.prefix)/\(route.id)" : nil
    }

    private static func isValidID(_ id: String) -> Bool {
        // The Worker additionally requires an alphanumeric first character.
        matches(id, #"\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z"#)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

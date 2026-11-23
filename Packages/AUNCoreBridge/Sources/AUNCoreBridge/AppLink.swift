import Foundation

/// A universal link on the videos host or `alummahnow.link` short-link host (Epic 22, `Apple#31` & `E22-D8`):
///
/// - videos host (`videos.[qa.|stage.]alummahnow.net`): `/app/auth/callback`, `/{en,ar}/{video,shorts,playlist,post,live,channels}/…`,
///   `/{en,ar}/@handle…`, `/app/studio/…`, `/{en,ar}/studio/…`
/// - short-link host (`[qa.|stage.]alummahnow.link`): `/v/<id>`, `/s/<id>`, `/e/<id>`, `/@<handle>`, `/c/<id>`, `/p/<id>`, `/l/<id>`
public enum AppLink: Equatable, Sendable {
    case video(id: String)
    case short(id: String)
    case live(id: String)
    case playlist(id: String)
    case post(id: String)
    case channel(handle: String)
    case channelID(id: String)
    case studio(StudioLink)
    /// The viewer's OAuth redirect on the web host; the whole URL carries the code and state.
    case authCallback(URL)

    /// The videos hosts links are accepted from: production, QA and stage.
    public static let hosts: Set<String> = [
        "videos.alummahnow.net", "videos.qa.alummahnow.net", "videos.stage.alummahnow.net",
        "videos.alummahnow.com", "videos.qa.alummahnow.com", "videos.stage.alummahnow.com",
    ]

    /// The short-link hosts (`alummahnow.link`) accepted for Universal Links and App Clips.
    public static let shortLinkHosts: Set<String> = [
        "alummahnow.link", "qa.alummahnow.link", "stage.alummahnow.link",
    ]

    /// Parses a Universal Link or `alummahnow.link` URL, or nil when it is not one of ours.
    public static func parse(
        _ url: URL, hosts: Set<String> = AppLink.hosts, shortHosts: Set<String> = AppLink.shortLinkHosts
    ) -> AppLink? {
        parseInvocation(url, hosts: hosts, shortHosts: shortHosts)?.link
    }

    /// Parses a link together with optional playback query parameters (`?t=`, `?list=`, `?index=`, `?lang=`).
    public static func parseInvocation(
        _ url: URL, hosts: Set<String> = AppLink.hosts, shortHosts: Set<String> = AppLink.shortLinkHosts
    ) -> AppLinkInvocation? {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return nil }
        let query = Self.queryItems(of: url)
        if shortHosts.contains(host) {
            guard let link = parseShortPath(url) else { return nil }
            return AppLinkInvocation(link: link, query: query, explicitLang: query["lang"])
        }
        guard hosts.contains(host) else { return nil }
        guard let (link, pathLang) = parseWebPath(url) else { return nil }
        return AppLinkInvocation(link: link, query: query, explicitLang: pathLang ?? query["lang"])
    }

    private static func parseShortPath(_ url: URL) -> AppLink? {
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let head = parts.first else { return nil }
        if head.hasPrefix("@") {
            let handle = String(head.dropFirst())
            return parts.count == 1 && ShortLinks.isValidHandle(handle) ? .channel(handle: handle) : nil
        }
        guard parts.count == 2, ShortLinks.isValidID(parts[1]) else { return nil }
        let id = parts[1]
        switch head {
        case "v": return .video(id: id)
        case "s": return .short(id: id)
        case "e": return .live(id: id)
        case "c": return .channelID(id: id)
        case "p": return .post(id: id)
        case "l": return .playlist(id: id)
        default: return nil
        }
    }

    private static func parseWebPath(_ url: URL) -> (AppLink, String?)? {
        var parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if parts.first == "app" {
            switch parts.dropFirst().first {
            case "auth" where parts.count == 3 && parts[2] == "callback": return (.authCallback(url), nil)
            case "studio": return (.studio(StudioLink(Array(parts.dropFirst(2)))), nil)
            default: return nil
            }
        }
        var locale: String?
        if let first = parts.first, ["en", "ar"].contains(first) {
            locale = first
            parts.removeFirst()
        }
        guard let head = parts.first else { return nil }
        if head.hasPrefix("@") {
            let handle = String(head.dropFirst())
            return handle.isEmpty ? nil : (.channel(handle: handle), locale)
        }
        if head == "studio" { return (.studio(StudioLink(Array(parts.dropFirst()))), locale) }
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        let id = parts[1]
        switch head {
        case "video": return (.video(id: id), locale)
        case "shorts": return (.short(id: id), locale)
        case "live": return (.live(id: id), locale)
        case "channels": return (.channelID(id: id), locale)
        case "playlist": return (.playlist(id: id), locale)
        case "post": return (.post(id: id), locale)
        default: return nil
        }
    }

    private static func queryItems(of url: URL) -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        var map: [String: String] = [:]
        for item in items {
            if let value = item.value, map[item.name] == nil { map[item.name] = value }
        }
        return map
    }

    /// The watch page's video for links that open one (videos and Shorts).
    public var videoID: String? {
        switch self {
        case .video(let id), .short(let id): id
        default: nil
        }
    }
}

/// Parsed deep link plus optional start position, playlist context, and language (`?t=`, `?list=`, `?index=`, `?lang=`).
public struct AppLinkInvocation: Equatable, Sendable {
    public var link: AppLink
    public var startSeconds: Int?
    public var playlistID: String?
    public var playlistIndex: Int?
    public var language: String?

    init(link: AppLink, query: [String: String], explicitLang: String?) {
        self.link = link
        if let rawT = query["t"], let seconds = Int(rawT), seconds >= 1 {
            self.startSeconds = seconds
        }
        if let rawList = query["list"], ShortLinks.isValidID(rawList) {
            self.playlistID = rawList
            if let rawIdx = query["index"], let idx = Int(rawIdx), idx >= 0 {
                self.playlistIndex = idx
            }
        }
        if let lang = explicitLang, ["en", "ar"].contains(lang) {
            self.language = lang
        }
    }
}

/// Builds `alummahnow.link` short links matching `packages/shared-types/src/short-links.ts` (`AlUmmahNowApple#31`).
public enum ShortLinks {
    public enum Target: Equatable, Sendable {
        case video(String)
        case short(String)
        case live(String)
        case channel(String)
        case handle(String)
        case post(String)
        case playlist(String)
    }

    public struct Options: Equatable, Sendable {
        public var startSeconds: Int?
        public var playlistID: String?
        public var playlistIndex: Int?
        public var languageCode: String?

        public init(
            startSeconds: Int? = nil, playlistID: String? = nil, playlistIndex: Int? = nil, languageCode: String? = nil
        ) {
            self.startSeconds = startSeconds
            self.playlistID = playlistID
            self.playlistIndex = playlistIndex
            self.languageCode = languageCode
        }
    }

    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64, let first = id.utf8.first, isASCIIAlnum(first) else { return false }
        return id.utf8.dropFirst().allSatisfy { isASCIIAlnum($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    public static func isValidHandle(_ handle: String) -> Bool {
        let bytes = Array(handle.utf8)
        guard (3...30).contains(bytes.count), let first = bytes.first, let last = bytes.last,
            isASCIIAlnum(first), isASCIIAlnum(last)
        else { return false }
        return bytes.dropFirst().dropLast().allSatisfy {
            isASCIIAlnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
        }
    }

    private static func isASCIIAlnum(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    /// Short-link origin for an API or site URL (`https://[qa.|stage.]alummahnow.link`), or nil on localhost/previews.
    public static func origin(for siteOrAPIURL: URL) -> URL? {
        guard let host = siteOrAPIURL.host()?.lowercased() else { return nil }
        if host == "alummahnow.link" || host.hasSuffix(".alummahnow.link") {
            return URL(string: "https://\(host)")
        }
        guard
            host == "alummahnow.net" || host.hasSuffix(".alummahnow.net")
                || host == "alummahnow.com" || host.hasSuffix(".alummahnow.com")
        else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        if labels.contains("qa") { return URL(string: "https://qa.alummahnow.link") }
        if labels.contains("stage") { return URL(string: "https://stage.alummahnow.link") }
        if labels.contains(where: { $0 == "preview" || $0 == "dev" || $0.hasPrefix("pr-") }) { return nil }
        return URL(string: "https://alummahnow.link")
    }

    public static func url(for siteOrAPIURL: URL, target: Target, options: Options = Options()) -> URL? {
        guard let base = origin(for: siteOrAPIURL), let path = path(for: target) else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = path
        var items: [URLQueryItem] = []
        if let listID = options.playlistID, isValidID(listID) {
            items.append(URLQueryItem(name: "list", value: listID))
            if let index = options.playlistIndex, index >= 0 {
                items.append(URLQueryItem(name: "index", value: String(index)))
            }
        }
        if let start = options.startSeconds, start >= 1 {
            items.append(URLQueryItem(name: "t", value: String(start)))
        }
        if options.languageCode?.lowercased().hasPrefix("ar") == true {
            items.append(URLQueryItem(name: "lang", value: "ar"))
        }
        if !items.isEmpty { components?.queryItems = items }
        return components?.url
    }

    /// Share-sheet URL for `environment`: the `alummahnow.link` short link when valid, else the full web URL.
    public static func shareURL(
        environment: AppEnvironment, target: Target, fallbackPath: String, options: Options = Options()
    ) -> URL {
        if let short = url(for: environment.apiBaseURL, target: target, options: options) {
            return short
        }
        let webHost = environment.name == "qa" ? "videos.qa.alummahnow.net" : "videos.alummahnow.net"
        let prefix = options.languageCode?.lowercased().hasPrefix("ar") == true ? "/ar" : "/en"
        let clean = fallbackPath.hasPrefix("/") ? fallbackPath : "/\(fallbackPath)"
        return URL(string: "https://\(webHost)\(prefix)\(clean)") ?? environment.apiBaseURL
    }

    private static func path(for target: Target) -> String? {
        switch target {
        case .video(let id): isValidID(id) ? "/v/\(id)" : nil
        case .short(let id): isValidID(id) ? "/s/\(id)" : nil
        case .live(let id): isValidID(id) ? "/e/\(id)" : nil
        case .channel(let id): isValidID(id) ? "/c/\(id)" : nil
        case .handle(let raw):
            {
                let trimmed = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
                return isValidHandle(trimmed) ? "/@\(trimmed)" : nil
            }()
        case .post(let id): isValidID(id) ? "/p/\(id)" : nil
        case .playlist(let id): isValidID(id) ? "/l/\(id)" : nil
        }
    }
}

/// Where a web Studio address points, mapped to the native Studio's sections.
public struct StudioLink: Equatable, Sendable {
    public enum Section: String, Sendable {
        case home, content, deleted, analytics
    }

    public var channelID: String?
    public var section: Section

    public init(channelID: String? = nil, section: Section) {
        self.channelID = channelID
        self.section = section
    }

    init(_ parts: [String]) {
        guard let first = parts.first else {
            self.init(section: .home)
            return
        }
        switch first {
        case "go": self.init(section: .home)
        case "video":
            self.init(section: parts.count >= 3 && parts[2] == "analytics" ? .analytics : .content)
        default:
            let rest = Array(parts.dropFirst())
            self.init(channelID: first, section: Self.section(rest))
        }
    }

    private static func section(_ rest: [String]) -> Section {
        guard let head = rest.first else { return .home }
        switch head {
        case "analytics": return .analytics
        case "deleted": return .deleted
        case "content":
            if rest.contains("deleted") { return .deleted }
            return rest.last == "analytics" ? .analytics : .content
        default: return .home
        }
    }
}

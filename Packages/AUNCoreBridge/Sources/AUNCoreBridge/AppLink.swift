import Foundation

/// A universal link on the videos host, as the apps claim them (videos admin → Mobile apps serves
/// `/.well-known/apple-app-site-association` with this path table; AlUmmahNow shared-types `MOBILE_APP_LINK_PATHS`):
///
/// - viewer: `/app/auth/callback`, `/{en,ar}/{video,shorts,live,playlist,post}/…`, `/{en,ar}/@handle…`, also without the locale
/// - studio: `/app/studio/…`, `/{en,ar}/studio/…`, also without the locale
public enum AppLink: Equatable, Sendable {
    case video(id: String)
    case short(id: String)
    case live(id: String)
    case playlist(id: String)
    case post(id: String)
    case channel(handle: String)
    case studio(StudioLink)
    /// The viewer's OAuth redirect on the web host; the whole URL carries the code and state.
    case authCallback(URL)

    /// The hosts links are accepted from: production, QA and stage videos sites.
    public static let hosts: Set<String> = [
        "videos.alummahnow.net", "videos.qa.alummahnow.net", "videos.stage.alummahnow.net",
    ]

    /// The link for a URL the system handed the app, or nil when it is not one of ours.
    public static func parse(_ url: URL, hosts: Set<String> = AppLink.hosts) -> AppLink? {
        guard url.scheme?.lowercased() == "https",
            url.user == nil, url.password == nil,
            let host = url.host()?.lowercased(), hosts.contains(host),
            url.absoluteString.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
        else {
            return nil
        }
        let rawSegments = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "")
            .split(separator: "/", omittingEmptySubsequences: true)
        let hasUnsafeSegment = rawSegments.contains { segment in
            let lower = segment.lowercased()
            return lower == "." || lower == ".." || lower.contains("%2e") || lower.contains("%2f") || lower.contains("%5c")
        }
        guard !hasUnsafeSegment else { return nil }
        var parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if parts.first == "app" {
            switch parts.dropFirst().first {
            case "auth" where parts.count == 3 && parts[2] == "callback": return .authCallback(url)
            case "studio":
                guard let studio = StudioLink.validated(Array(parts.dropFirst(2))) else { return nil }
                return .studio(studio)
            default: return nil
            }
        }
        if let first = parts.first, ["en", "ar"].contains(first) { parts.removeFirst() }
        guard let head = parts.first else { return nil }
        if head.hasPrefix("@") {
            let handle = String(head.dropFirst())
            return SafeInput.isSafePathSegment(handle) ? .channel(handle: handle) : nil
        }
        if head == "studio" {
            guard let studio = StudioLink.validated(Array(parts.dropFirst())) else { return nil }
            return .studio(studio)
        }
        guard parts.count >= 2, SafeInput.isSafePathSegment(parts[1]) else { return nil }
        let id = parts[1]
        switch head {
        case "video": return .video(id: id)
        case "shorts": return .short(id: id)
        case "live": return .live(id: id)
        case "playlist": return .playlist(id: id)
        case "post": return .post(id: id)
        default: return nil
        }
    }

    /// The watch page's video for links that open one (videos and Shorts).
    public var videoID: String? {
        switch self {
        case .video(let id), .short(let id): id
        default: nil
        }
    }
}

/// Where a web Studio address points, mapped to the native Studio's sections. The web routes are
/// `/studio`, `/studio/<channelId>[/dashboard|/analytics|/content/…|/site|…]` and `/studio/video/<videoId>/<action>`.
public struct StudioLink: Equatable, Sendable {
    public enum Section: String, Sendable {
        case home, content, deleted, analytics
    }

    /// The channel in the address, when it names one.
    public var channelID: String?
    public var section: Section

    public init(channelID: String? = nil, section: Section) {
        self.channelID = channelID
        self.section = section
    }

    static func validated(_ parts: [String]) -> StudioLink? {
        let link = StudioLink(parts)
        if let channelID = link.channelID, !SafeInput.isSafePathSegment(channelID) { return nil }
        return link
    }

    init(_ parts: [String]) {
        guard let first = parts.first else {
            self.init(section: .home)
            return
        }
        switch first {
        case "go": self.init(section: .home)
        case "video":
            // `/studio/video/<id>/analytics` opens the stats; edit and the other actions open Content.
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

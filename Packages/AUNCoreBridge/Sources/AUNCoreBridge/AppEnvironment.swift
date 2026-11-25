import Foundation
import os

public enum AUNLog {
    public static let network = Logger(subsystem: "net.alummahnow", category: "network")
    public static let player = Logger(subsystem: "net.alummahnow", category: "player")
    public static let studio = Logger(subsystem: "net.alummahnow", category: "studio")
    /// The Admin app. Never log a URL, a token or a review's content here.
    public static let admin = Logger(subsystem: "net.alummahnow", category: "admin")
}

public struct AppEnvironment: Hashable, Sendable {
    public var name: String
    public var apiBaseURL: URL
    /// admin-api, which serves the public site settings such as the theme.
    public var adminAPIBaseURL: URL
    /// The OAuth issuer (auth worker).
    public var authIssuer: URL
    /// This app's public OAuth client on that issuer; nil for apps without sign-in.
    public var oauthClientID: String?

    public init(
        name: String, apiBaseURL: URL, adminAPIBaseURL: URL = AppEnvironment.qaAdminAPI,
        authIssuer: URL = AppEnvironment.qaAuthIssuer, oauthClientID: String? = nil
    ) {
        self.name = name
        self.apiBaseURL = apiBaseURL
        self.adminAPIBaseURL = adminAPIBaseURL
        self.authIssuer = authIssuer
        self.oauthClientID = oauthClientID
    }

    public static let qaAdminAPI = URL(string: "https://admin.api.qa.alummahnow.net")!
    public static let qaAuthIssuer = URL(string: "https://auth.qa.alummahnow.net")!
    public static let qaWebBase = URL(string: "https://videos.qa.alummahnow.net")!
    public static let qaWwwBase = URL(string: "https://www.qa.alummahnow.net")!
    public static let qa = AppEnvironment(name: "qa", apiBaseURL: URL(string: "https://videos.api.qa.alummahnow.net")!)

    /// Public videos web origin derived from `apiBaseURL`. Falls back to QA, never to production.
    public var webBaseURL: URL {
        guard let host = apiBaseURL.host?.lowercased() else { return Self.qaWebBase }
        if host == "videos.api.alummahnow.net" || host == "videos.alummahnow.net" {
            return URL(string: "https://videos.alummahnow.net")!
        }
        if host.contains(".api.") {
            let webHost = host.replacingOccurrences(of: ".api.", with: ".")
            if let url = URL(string: "https://\(webHost)") { return url }
        }
        return Self.qaWebBase
    }

    /// Public corporate/legal website origin (`www`) derived from `apiBaseURL`. Falls back to QA, never to production.
    public var wwwBaseURL: URL {
        guard let host = apiBaseURL.host?.lowercased() else { return Self.qaWwwBase }
        if host == "videos.api.alummahnow.net" || host == "videos.alummahnow.net" {
            return URL(string: "https://www.alummahnow.net")!
        }
        if host.hasSuffix(".staging.alummahnow.net") {
            return URL(string: "https://www.staging.alummahnow.net")!
        }
        if host.hasSuffix(".stage.alummahnow.net") {
            return URL(string: "https://www.stage.alummahnow.net")!
        }
        return Self.qaWwwBase
    }

    /// Reads the values the build configuration wrote to Info.plist. Falls back to QA, never to production.
    public static func fromInfoDictionary(_ info: [String: Any]?) -> AppEnvironment {
        guard let base = info?["AUNAPIBaseURL"] as? String, let url = URL(string: base), url.scheme == "https",
            let name = info?["AUNEnvironment"] as? String
        else { return .qa }
        func secure(_ key: String) -> URL? {
            (info?[key] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        }
        let client = (info?["AUNOAuthClientID"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        return AppEnvironment(
            name: name, apiBaseURL: url, adminAPIBaseURL: secure("AUNAdminAPIBaseURL") ?? qaAdminAPI,
            authIssuer: secure("AUNAuthIssuer") ?? qaAuthIssuer, oauthClientID: client)
    }
}

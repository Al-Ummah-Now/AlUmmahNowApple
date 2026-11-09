import Foundation
import os

public enum AUNLog {
    public static let network = Logger(subsystem: "net.alummahnow", category: "network")
    public static let player = Logger(subsystem: "net.alummahnow", category: "player")
    public static let studio = Logger(subsystem: "net.alummahnow", category: "studio")
}

public struct AppEnvironment: Hashable, Sendable {
    public var name: String
    public var apiBaseURL: URL
    /// admin-api, which serves the public site settings such as the theme.
    public var adminAPIBaseURL: URL

    public init(name: String, apiBaseURL: URL, adminAPIBaseURL: URL = AppEnvironment.qaAdminAPI) {
        self.name = name
        self.apiBaseURL = apiBaseURL
        self.adminAPIBaseURL = adminAPIBaseURL
    }

    public static let qaAdminAPI = URL(string: "https://admin.api.qa.alummahnow.net")!
    public static let qa = AppEnvironment(name: "qa", apiBaseURL: URL(string: "https://videos.api.qa.alummahnow.net")!)

    /// Reads the values the build configuration wrote to Info.plist. Falls back to QA, never to production.
    public static func fromInfoDictionary(_ info: [String: Any]?) -> AppEnvironment {
        guard let base = info?["AUNAPIBaseURL"] as? String, let url = URL(string: base), url.scheme == "https",
            let name = info?["AUNEnvironment"] as? String
        else { return .qa }
        let admin = (info?["AUNAdminAPIBaseURL"] as? String).flatMap(URL.init(string:)).flatMap {
            $0.scheme == "https" ? $0 : nil
        }
        return AppEnvironment(name: name, apiBaseURL: url, adminAPIBaseURL: admin ?? qaAdminAPI)
    }
}

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

    public init(name: String, apiBaseURL: URL) {
        self.name = name
        self.apiBaseURL = apiBaseURL
    }

    public static let qa = AppEnvironment(name: "qa", apiBaseURL: URL(string: "https://videos.api.qa.alummahnow.net")!)

    /// Reads the values the build configuration wrote to Info.plist. Falls back to QA, never to production.
    public static func fromInfoDictionary(_ info: [String: Any]?) -> AppEnvironment {
        guard let base = info?["AUNAPIBaseURL"] as? String, let url = URL(string: base), url.scheme == "https",
            let name = info?["AUNEnvironment"] as? String
        else { return .qa }
        return AppEnvironment(name: name, apiBaseURL: url)
    }
}

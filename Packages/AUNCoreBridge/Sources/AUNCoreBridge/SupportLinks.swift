import Foundation

/// Public help, contact, privacy, terms and guidelines URLs opened in the browser from Viewer and Studio apps
/// (App Store 1.2, 5.1.1(i); Play UGC and User Data). Always derived from the app's `AppEnvironment` (never
/// silently defaulting to production).
public enum AUNSupportLinks {
    private static func localeSegment(_ language: String) -> String {
        language.lowercased().hasPrefix("ar") ? "ar" : "en"
    }

    public static func help(language: String, environment: AppEnvironment) -> URL {
        environment.webBaseURL.appendingPathComponent(localeSegment(language)).appendingPathComponent("help")
    }

    public static func contact(language: String, environment: AppEnvironment) -> URL {
        environment.webBaseURL.appendingPathComponent(localeSegment(language)).appendingPathComponent("contact")
    }

    public static func communityGuidelines(language: String, environment: AppEnvironment) -> URL {
        environment.webBaseURL
            .appendingPathComponent(localeSegment(language))
            .appendingPathComponent("community-guidelines")
    }

    public static func privacy(language: String, environment: AppEnvironment) -> URL {
        URL(string: "\(environment.wwwBaseURL.absoluteString)/\(localeSegment(language))/privacy/")!
    }

    public static func terms(language: String, environment: AppEnvironment) -> URL {
        URL(string: "\(environment.wwwBaseURL.absoluteString)/\(localeSegment(language))/terms/")!
    }
}

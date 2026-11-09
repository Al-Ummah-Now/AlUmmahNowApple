import AUNCoreBridge
import Foundation
import Observation

/// The site theme an admin set (`site.theme`), for every window of the app.
///
/// Order of truth: a `-AUNSiteTheme <id>` launch argument (UI tests and screenshots), then the last value the
/// endpoint returned (cached across launches), then Fawanees, the site default. Unknown ids reduce to Fawanees, as
/// on the web. A failed refresh keeps what is showing.
@MainActor @Observable
public final class SiteThemeStore {
    public private(set) var id: FanousThemeID

    private let service: (any SiteThemeServicing)?
    private let defaults: UserDefaults
    private let pinned: Bool

    static let cacheKey = "AUNSiteThemeCache"
    static let overrideKey = "AUNSiteTheme"

    public init(service: (any SiteThemeServicing)?, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        if let forced = defaults.string(forKey: Self.overrideKey) {
            id = FanousThemeID(siteValue: forced)
            pinned = true
        } else {
            id = FanousThemeID(siteValue: defaults.string(forKey: Self.cacheKey))
            pinned = false
        }
    }

    /// The live store: the endpoint of the environment this build points at, or none with `-AUNUseFixtures YES`.
    public static func live(defaults: UserDefaults = .standard, info: [String: Any]? = Bundle.main.infoDictionary)
        -> SiteThemeStore
    {
        let service: (any SiteThemeServicing)? =
            defaults.bool(forKey: "AUNUseFixtures")
            ? nil : NativeSiteThemeService(adminAPIBaseURL: AppEnvironment.fromInfoDictionary(info).adminAPIBaseURL)
        return SiteThemeStore(service: service, defaults: defaults)
    }

    /// Reads the endpoint and, on success, shows and caches the theme. Errors leave the current theme in place.
    public func refresh() async {
        guard !pinned, let service else { return }
        do {
            let value = try await service.siteTheme()
            let resolved = FanousThemeID(siteValue: value)
            defaults.set(resolved.rawValue, forKey: Self.cacheKey)
            if resolved != id { id = resolved }
        } catch {
            AUNLog.network.info("site theme unavailable, keeping \(self.id.rawValue, privacy: .public)")
        }
    }
}

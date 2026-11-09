import AUNCoreBridge
import Foundation
import Testing

@testable import AUNDesign

private struct Failing: SiteThemeServicing {
    func siteTheme() async throws -> String { throw CoreError.http(status: 404) }
}

@MainActor @Suite struct SiteThemeStoreTests {
    private func defaults() throws -> UserDefaults { try #require(UserDefaults(suiteName: UUID().uuidString)) }

    @Test func startsOnFawaneesWithNothingCached() throws {
        #expect(SiteThemeStore(service: nil, defaults: try defaults()).id == .fawanees)
    }

    @Test func followsTheEndpointAndCachesIt() async throws {
        let store = try defaults()
        let theme = SiteThemeStore(service: FixedSiteThemeService("nahas"), defaults: store)
        await theme.refresh()
        #expect(theme.id == .nahas)
        // The next launch, offline, starts on the cached theme.
        let offline = SiteThemeStore(service: Failing(), defaults: store)
        #expect(offline.id == .nahas)
        await offline.refresh()
        #expect(offline.id == .nahas)
    }

    @Test func fallsBackToFawaneesOfflineWithNoCache() async throws {
        let theme = SiteThemeStore(service: Failing(), defaults: try defaults())
        await theme.refresh()
        #expect(theme.id == .fawanees)
    }

    @Test func unknownValuesReduceToFawanees() async throws {
        let theme = SiteThemeStore(service: FixedSiteThemeService("retro"), defaults: try defaults())
        await theme.refresh()
        #expect(theme.id == .fawanees)
    }

    @Test func launchArgumentPinsTheTheme() async throws {
        let store = try defaults()
        store.set("zujaj", forKey: "AUNSiteTheme")
        let theme = SiteThemeStore(service: FixedSiteThemeService("lantern"), defaults: store)
        await theme.refresh()
        #expect(theme.id == .zujaj)
    }
}

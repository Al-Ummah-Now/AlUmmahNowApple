import AUNCoreKit
import AUNDesign
import AUNStudio
import SwiftUI

@main
struct StudioMacApp: App {
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    private let services = StudioBootstrap.services()
    private let preferences = StudioBootstrap.preferences()

    var body: some Scene {
        WindowGroup {
            StudioRootView(
                services: services,
                authenticator: StudioBootstrap.usesFixtures()
                    ? FixtureWebAuthenticator() as any WebAuthenticating : SystemWebAuthenticator(),
                preferences: preferences
            )
            .fanousRoot(settings, siteTheme: siteTheme)
            .environment(settings)
        }
        // Fits a 1280x800 screen (and CI's), so the bulk bar at the bottom of Content is on screen in a fresh window.
        .defaultSize(width: 1100, height: 680)
    }
}

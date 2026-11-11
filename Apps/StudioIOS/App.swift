import AUNCoreKit
import AUNDesign
import AUNStudio
import SwiftUI

@main
struct StudioIOSApp: App {
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
    }
}

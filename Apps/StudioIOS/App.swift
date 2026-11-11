import AUNCoreBridge
import AUNCoreKit
import AUNDesign
import AUNStudio
import SwiftUI

/// Hands iOS the completion handler when it relaunches Studio for finished background uploads.
final class StudioAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == TUSTransfer.backgroundIdentifier else { return completionHandler() }
        nonisolated(unsafe) let completion = completionHandler
        StudioBootstrap.liveTransfer.handleBackgroundEvents { completion() }
    }
}

@main
struct StudioIOSApp: App {
    @UIApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
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

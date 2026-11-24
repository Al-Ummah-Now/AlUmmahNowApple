import AUNCoreBridge
import AUNDesign
import AUNFeatures
import SwiftUI

@main
struct ViewerMacApp: App {
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    private let core = ViewerBootstrap.makeCore()

    var body: some Scene {
        WindowGroup {
            ViewerRootView(core: core)
                .fanousRoot(settings, siteTheme: siteTheme)
                .environment(settings)
        }
        // Fits a 1280x800 screen, so the first rail is on screen in a fresh window.
        .defaultSize(width: 1100, height: 700)
        WindowGroup(id: ViewerRootView.watchWindowID, for: ViewerDestination.self) { $destination in
            if let destination {
                WatchWindow(destination: destination, core: core)
                    .fanousRoot(settings, siteTheme: siteTheme)
                    .environment(settings)
            }
        }
    }
}

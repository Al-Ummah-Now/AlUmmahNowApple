import AUNCoreBridge
import AUNDesign
import AUNFeatures
import SwiftUI

@main
struct ViewerTVApp: App {
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    private let core = ViewerBootstrap.makeCore()

    var body: some Scene {
        WindowGroup {
            ViewerRootView(core: core)
                .fanousRoot(settings, siteTheme: siteTheme)
                .environment(settings)
        }
    }
}

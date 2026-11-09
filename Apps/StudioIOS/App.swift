import AUNDesign
import AUNStudio
import SwiftUI

@main
struct StudioIOSApp: App {
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()

    var body: some Scene {
        WindowGroup {
            StudioIOSRoot()
                .fanousRoot(settings, siteTheme: siteTheme)
                .environment(settings)
        }
    }
}

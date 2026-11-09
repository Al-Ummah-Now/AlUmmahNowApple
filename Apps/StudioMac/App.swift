import AUNCoreBridge
import AUNDesign
import AUNStudio
import SwiftUI

@main
struct StudioMacApp: App {
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    private let core = CoreBridge.temporaryNative(environment: .fromInfoDictionary(Bundle.main.infoDictionary))

    var body: some Scene {
        WindowGroup {
            StudioMacRoot(core: core)
                .fanousRoot(settings, siteTheme: siteTheme)
                .environment(settings)
        }
    }
}

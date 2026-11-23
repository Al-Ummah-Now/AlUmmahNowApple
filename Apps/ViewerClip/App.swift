import AUNCoreBridge
import AUNDesign
import AUNViewerClip
import SwiftUI

@main
struct ViewerClipApp: App {
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    private let core = CoreBridge.temporaryNative(environment: .fromInfoDictionary(Bundle.main.infoDictionary))

    var body: some Scene {
        WindowGroup {
            ViewerClipRootView(core: core)
                .fanousRoot(settings, siteTheme: siteTheme)
                .environment(settings)
        }
    }
}

import AUNCoreBridge
import AUNDesign
import AUNFeatures
import SwiftUI

@main
struct ViewerMacApp: App {
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    private let core = ViewerBootstrap.makeCore()

    init() {
        // The window chrome in the app's language: in Arabic the traffic lights, title and toolbar mirror, and the
        // settings menu stays in the toolbar (an AppKit left-to-right window under a right-to-left view dropped it).
        AppKitLayoutDirection.match(AppSettings().language)
        AutomationWindow.forgetSavedFrames()
    }

    var body: some Scene {
        WindowGroup {
            ViewerRootView(core: core)
                .fanousRoot(settings, siteTheme: siteTheme)
                .environment(settings)
        }
        // Fits a 1280x800 screen, so the first rail is on screen in a fresh window.
        .defaultSize(width: 1100, height: AutomationWindow.height(700))
        WindowGroup(id: ViewerRootView.watchWindowID, for: String.self) { $videoID in
            if let videoID {
                WatchWindow(videoID: videoID, core: core)
                    .fanousRoot(settings, siteTheme: siteTheme)
                    .environment(settings)
            }
        }
        // Wide enough for the player with the title, channel and chapters beside it.
        .defaultSize(width: 1100, height: AutomationWindow.watchHeight(680))
    }
}

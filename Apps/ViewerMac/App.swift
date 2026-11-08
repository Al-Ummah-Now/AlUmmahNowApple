import AUNCoreBridge
import AUNDesign
import AUNFeatures
import SwiftUI

@main
struct ViewerMacApp: App {
    @State private var settings = AppSettings()
    private let core = ViewerBootstrap.makeCore()

    var body: some Scene {
        WindowGroup {
            ViewerRootView(core: core)
                .fanousRoot(settings)
                .environment(settings)
        }
        WindowGroup(id: ViewerRootView.watchWindowID, for: String.self) { $videoID in
            if let videoID {
                WatchWindow(videoID: videoID, core: core)
                    .fanousRoot(settings)
                    .environment(settings)
            }
        }
    }
}

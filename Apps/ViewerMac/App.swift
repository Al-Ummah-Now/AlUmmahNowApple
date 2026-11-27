import AUNCoreBridge
import AUNCoreKit
import AUNDesign
import AUNFeatures
import SwiftUI

@main
struct ViewerMacApp: App {
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    private let core: CoreBridge

    init() {
        AppKitLayoutDirection.match(AppSettings().language)
        let fixtures = UserDefaults.standard.bool(forKey: "AUNUseFixtures")
        let environment = AppEnvironment.fromInfoDictionary(Bundle.main.infoDictionary)
        let telemetry = CoreTelemetryService.live(
            environment: environment, userAgentPrefix: "AlUmmahNow-Viewer-Mac",
            bufferFilename: "viewer-telemetry-buffer.json", fixtures: fixtures)
        if !fixtures { CrashTelemetryHook.install(service: telemetry) }
        core = ViewerBootstrap.makeCore(telemetry: telemetry)
    }

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

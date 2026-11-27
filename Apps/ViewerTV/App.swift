import AUNCoreBridge
import AUNCoreKit
import AUNDesign
import AUNFeatures
import SwiftUI

@main
struct ViewerTVApp: App {
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    private let core: CoreBridge

    init() {
        let fixtures = UserDefaults.standard.bool(forKey: "AUNUseFixtures")
        let environment = AppEnvironment.fromInfoDictionary(Bundle.main.infoDictionary)
        let telemetry = CoreTelemetryService.live(
            environment: environment, userAgentPrefix: "AlUmmahNow-Viewer-TV",
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
    }
}

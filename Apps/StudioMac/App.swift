import AUNCoreBridge
import AUNDesign
import AUNStudio
import SwiftUI

@main
struct StudioMacApp: App {
    @State private var settings = AppSettings()
    private let core = CoreBridge.temporaryNative(environment: .fromInfoDictionary(Bundle.main.infoDictionary))

    var body: some Scene {
        WindowGroup {
            StudioMacRoot(core: core)
                .fanousRoot(settings)
                .environment(settings)
        }
    }
}

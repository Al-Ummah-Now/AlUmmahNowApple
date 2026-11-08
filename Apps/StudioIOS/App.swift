import AUNDesign
import AUNStudio
import SwiftUI

@main
struct StudioIOSApp: App {
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            StudioIOSRoot()
                .fanousRoot(settings)
                .environment(settings)
        }
    }
}

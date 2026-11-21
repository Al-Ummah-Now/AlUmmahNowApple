#if os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import AUNPlayer
    import SwiftUI

    /// macOS shell: the sidebar is the home for later sections, and each video opens in its own window.
    public struct ViewerRootView: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.openWindow) private var openWindow
        @State private var selection: String? = "home"
        private let core: CoreBridge

        public init(core: CoreBridge) { self.core = core }

        public var body: some View {
            NavigationSplitView {
                List(selection: $selection) {
                    Label(l10n("home.title"), systemImage: "house").tag("home")
                        .listRowBackground(
                            selection == "home"
                                ? FanousSurfaceKind(kind: .active, shape: .rounded(8)).padding(.horizontal, 6) : nil)
                }
                .scrollContentBackground(.hidden)
                .fanousMaterial(.rail)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
            } detail: {
                HomeView(catalog: core.catalog) { openWindow(id: Self.watchWindowID, value: $0.id) }
                    .toolbar { ToolbarItem(placement: .primaryAction) { SettingsMenu() } }
                    .navigationTitle(l10n("app.name"))
                    // The web header's colours on the window toolbar, as on iPhone and iPad, so its icons show in light.
                    .fanousNavigationBar()
            }
            .frame(minWidth: 900, minHeight: 560)
            // A universal link reuses this window (instead of a new one) and opens the video in its own window.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onOpenURL { url in
                if let id = ViewerLinks.videoID(for: url) { openWindow(id: Self.watchWindowID, value: id) }
            }
        }

        public static let watchWindowID = "watch"
    }

    /// One video window. Space plays or pauses, and arrow keys skip in the reading direction.
    public struct WatchWindow: View {
        @Environment(\.l10n) private var l10n
        private let videoID: String
        private let core: CoreBridge

        public init(videoID: String, core: CoreBridge) {
            self.videoID = videoID
            self.core = core
        }

        public var body: some View {
            WatchView(videoID: videoID, catalog: core.catalog).frame(minWidth: 860, minHeight: 480)
                // The window title in the app's language («الأمة الآن»), not the system's bundle name.
                .navigationTitle(l10n("app.name"))
                .fanousNavigationBar()
        }
    }

    enum SkipKey {
        /// Seconds to skip for a horizontal arrow key. Right moves forward in LTR and backward in RTL.
        static func delta(isRightArrow: Bool, direction: LayoutDirection) -> Double {
            let forward = isRightArrow == (direction == .leftToRight)
            return forward ? PlayerController.skipInterval : -PlayerController.skipInterval
        }
    }
#endif

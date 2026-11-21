#if os(iOS)
    import AUNCoreBridge
    import AUNDesign
    import SwiftUI

    /// iPhone and iPad shell.
    public struct ViewerRootView: View {
        @Environment(\.l10n) private var l10n
        @State private var path: [String] = []
        private let core: CoreBridge

        /// `initialVideoID` opens a watch page at launch (`-AUNOpenVideo <id>`), for UI automation.
        public init(core: CoreBridge, initialVideoID: String? = UserDefaults.standard.string(forKey: "AUNOpenVideo")) {
            self.core = core
            _path = State(initialValue: initialVideoID.map { [$0] } ?? [])
        }

        /// Room for iPadOS's window resize corner under scrolled content.
        private static var corner: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 12 : 0 }

        public var body: some View {
            NavigationStack(path: $path) {
                HomeView(catalog: core.catalog) { path.append($0.id) }
                    .navigationTitle(l10n("app.name"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsMenu() } }
                    .fanousNavigationBar()
                    .fanousBottomEdge(corner: Self.corner)
                    .navigationDestination(for: String.self) { id in
                        WatchView(videoID: id, catalog: core.catalog)
                            .navigationBarTitleDisplayMode(.inline)
                            .fanousNavigationBar()
                            .fanousBottomEdge(corner: Self.corner)
                    }
            }
            .onOpenURL { url in
                if let id = ViewerLinks.videoID(for: url) { path = [id] }
            }
        }
    }
#endif

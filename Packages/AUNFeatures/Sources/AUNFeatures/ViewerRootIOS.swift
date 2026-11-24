#if os(iOS)
    import AUNCoreBridge
    import AUNDesign
    import SwiftUI

    /// iPhone and iPad shell.
    public struct ViewerRootView: View {
        @Environment(\.l10n) private var l10n
        @State private var path: [ViewerDestination] = []
        private let core: CoreBridge

        /// `initial` opens a page at launch (`-AUNOpenVideo <id>`, `-AUNOpenLive <id>`), for UI automation.
        public init(core: CoreBridge, initial: ViewerDestination? = .launch()) {
            self.core = core
            _path = State(initialValue: initial.map { [$0] } ?? [])
        }

        public var body: some View {
            NavigationStack(path: $path) {
                HomeView(core: core) { path.append($0) }
                    .navigationTitle(l10n("app.name"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsMenu() } }
                    .fanousNavigationBar()
                    .navigationDestination(for: ViewerDestination.self) { destination in
                        screen(destination).navigationBarTitleDisplayMode(.inline).fanousNavigationBar()
                    }
            }
            .onOpenURL { url in
                if let destination = ViewerLinks.destination(for: url) { path = [destination] }
            }
        }

        @ViewBuilder private func screen(_ destination: ViewerDestination) -> some View {
            switch destination {
            case .video(let id):
                WatchView(videoID: id, catalog: core.catalog, webBaseURL: core.environment.webBaseURL)
            case .live(let id): LiveWatchView(streamID: id, core: core)
            case .liveList: LiveListView(live: core.live) { path.append(.live($0.id)) }
            }
        }
    }
#endif

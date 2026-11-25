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
        /// Something is on air or coming: the Live section is there.
        @State private var hasLive = false
        @State private var showingBlocked = false
        private let core: CoreBridge

        public init(core: CoreBridge) { self.core = core }

        public var body: some View {
            NavigationSplitView {
                List(selection: $selection) {
                    Label(l10n("home.title"), systemImage: "house").tag("home")
                        .listRowBackground(
                            selection == "home"
                                ? FanousSurfaceKind(kind: .active, shape: .rounded(8)).padding(.horizontal, 6) : nil)
                    if hasLive || selection == "live" {
                        Label(l10n("live.title"), systemImage: "dot.radiowaves.left.and.right").tag("live")
                            .listRowBackground(
                                selection == "live"
                                    ? FanousSurfaceKind(kind: .active, shape: .rounded(8)).padding(.horizontal, 6) : nil)
                    }
                }
                .scrollContentBackground(.hidden)
                .fanousMaterial(.rail)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
            } detail: {
                detail
                    .toolbar { ToolbarItem { SettingsMenu { showingBlocked = true } } }
                    .navigationTitle(l10n("app.name"))
            }
            .sheet(isPresented: $showingBlocked) {
                BlockedListSheet(store: .shared)
            }
            .frame(minWidth: 900, minHeight: 560)
            // A universal link reuses this window (instead of a new one) and opens the video in its own window.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onOpenURL { url in
                if let destination = ViewerLinks.destination(for: url) { open(destination) }
            }
        }

        @ViewBuilder private var detail: some View {
            if selection == "live" {
                LiveListView(live: core.live) { open(.live($0.id)) }
            } else {
                HomeView(core: core, hasLive: $hasLive, open: open)
            }
        }

        private func open(_ destination: ViewerDestination) {
            switch destination {
            case .liveList: selection = "live"
            case .video, .live: openWindow(id: Self.watchWindowID, value: destination)
            }
        }

        public static let watchWindowID = "watch"
    }

    /// One video window. Space plays or pauses, and arrow keys skip in the reading direction.
    public struct WatchWindow: View {
        private let destination: ViewerDestination
        private let core: CoreBridge

        public init(destination: ViewerDestination, core: CoreBridge) {
            self.destination = destination
            self.core = core
        }

        public var body: some View {
            Group {
                switch destination {
                case .video(let id):
                    WatchView(videoID: id, catalog: core.catalog, webBaseURL: core.environment.webBaseURL)
                case .live(let id): LiveWatchView(streamID: id, core: core)
                case .liveList: EmptyView()
                }
            }
            .frame(minWidth: 860, minHeight: 480)
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

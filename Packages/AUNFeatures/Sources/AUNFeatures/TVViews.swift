#if os(tvOS)
    import AUNCoreBridge
    import AUNDesign
    import AUNPlayer
    import SwiftUI

    /// Apple TV shell: focus-driven, no touch affordances.
    public struct ViewerRootView: View {
        @State private var path: [ViewerDestination] = []
        private let core: CoreBridge

        public init(core: CoreBridge, initial: ViewerDestination? = .launch()) {
            self.core = core
            _path = State(initialValue: initial.map { [$0] } ?? [])
        }

        public var body: some View {
            NavigationStack(path: $path) {
                TVHomeView(core: core) { path.append($0) }
                    .navigationDestination(for: ViewerDestination.self) { destination in
                        switch destination {
                        case .video(let id):
                            TVWatchView(videoID: id, catalog: core.catalog, webBaseURL: core.environment.webBaseURL)
                        case .live(let id): TVLiveWatchView(streamID: id, core: core)
                        case .liveList: EmptyView()
                        }
                    }
            }
        }
    }

    struct TVHomeView: View {
        @Environment(\.l10n) private var l10n
        @State private var model: HomeViewModel
        @State private var live: LiveListModel
        let open: (ViewerDestination) -> Void

        init(core: CoreBridge, open: @escaping (ViewerDestination) -> Void) {
            _model = State(initialValue: HomeViewModel(catalog: core.catalog))
            _live = State(initialValue: LiveListModel(live: core.live))
            self.open = open
        }

        var body: some View {
            ZStack {
                Rectangle().fill(Fanous.background).ignoresSafeArea()
                switch model.state {
                case .loading:
                    ProgressView(l10n("common.loading"))
                case .failed:
                    ErrorStateView { Task { await model.load() } }
                case .loaded(let rails) where rails.isEmpty:
                    Text(l10n("home.empty")).foregroundStyle(Fanous.textSecondary)
                case .loaded(let rails):
                    content(rails)
                }
            }
            .task { await model.load() }
            .task { await live.load() }
        }

        private func content(_ rails: [HomeRail]) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 48) {
                    if let hero = rails.first?.videos.first { TVHero(video: hero) { open(.video(hero.id)) } }
                    if !live.isEmpty { liveRail }
                    ForEach(rails) { rail in
                        VStack(alignment: .leading, spacing: 20) {
                            RailHeader(kind: rail.kind)
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: 40) {
                                    ForEach(rail.videos) { video in
                                        Button {
                                            open(.video(video.id))
                                        } label: {
                                            VideoCardContent(video: video).frame(width: 420).padding(12)
                                        }
                                        .buttonStyle(.card)
                                        .accessibilityIdentifier("video-card-\(rail.kind.rawValue)-\(video.id)")
                                    }
                                }
                                .padding(.vertical, 24)
                            }
                            .scrollClipDisabled()
                        }
                    }
                    TVSettingsRow()
                }
                .padding(.horizontal, 60)
            }
        }

        private var liveRail: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text(l10n("live.title")).fanousFont(.title).fontWeight(.bold).foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(live.onAir + live.coming) { stream in
                            Button {
                                open(.live(stream.id))
                            } label: {
                                LiveCardContent(stream: stream).frame(width: 420).padding(12)
                            }
                            .buttonStyle(.card)
                            .accessibilityIdentifier("live-card-\(stream.id)")
                        }
                    }
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
            }
        }
    }

    struct TVHero: View {
        @Environment(\.l10n) private var l10n
        let video: Video
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 40) {
                    ThumbnailImage(url: video.thumbnailURL).frame(width: 640).clipShape(RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(video.displayTitle(l10n.language)).font(.title2.weight(.bold)).foregroundStyle(Fanous.textPrimary)
                        Text(video.displayDescription(l10n.language)).foregroundStyle(Fanous.textSecondary).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            .buttonStyle(.card)
            .accessibilityIdentifier("hero")
        }
    }

    struct TVSettingsRow: View {
        @Environment(AppSettings.self) private var settings
        @Environment(\.l10n) private var l10n

        var body: some View {
            HStack(spacing: 24) {
                Button("\(l10n("common.language")): \(l10n("language.\(settings.language.rawValue)"))") {
                    settings.language = settings.language == .ar ? .en : .ar
                }
                .accessibilityIdentifier("language-toggle")
                Button("\(l10n("common.theme")): \(l10n("theme.\(settings.theme.rawValue)"))") {
                    let all = AppTheme.allCases
                    let next = ((all.firstIndex(of: settings.theme) ?? 0) + 1) % all.count
                    settings.theme = all[next]
                }
            }
            .padding(.bottom, 40)
        }
    }

    /// Full-screen playback; the system transport bar holds quality, speed and subtitles.
    struct TVWatchView: View {
        @Environment(\.l10n) private var l10n
        @State private var model: WatchViewModel
        @State private var showingReport = false
        private let webBaseURL: URL

        init(videoID: String, catalog: any CatalogServicing, webBaseURL: URL) {
            _model = State(initialValue: WatchViewModel(videoID: videoID, catalog: catalog))
            self.webBaseURL = webBaseURL
        }

        var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()
                switch model.state {
                case .loading:
                    ProgressView(l10n("common.loading"))
                case .failed:
                    ErrorStateView { Task { await model.load(language: l10n.language) } }
                case .loaded(let content):
                    Group {
                        if content.video.isPlayable {
                            PlayerSurface(controller: model.player).ignoresSafeArea().accessibilityIdentifier("player")
                        } else {
                            Text(l10n("watch.notReady")).foregroundStyle(Fanous.textPrimary).accessibilityIdentifier(
                                "watch-not-ready")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            showingReport = true
                        } label: {
                            Label(l10n("safety.report.video"), systemImage: "flag")
                        }
                        .padding(40)
                        .accessibilityIdentifier("tv-report-video")
                    }
                    .sheet(isPresented: $showingReport) {
                        VStack(spacing: 24) {
                            Text(l10n("safety.report.video")).font(.title2.weight(.bold))
                            Text(
                                l10n(
                                    "safety.report.tvBody",
                                    ViewerReportURL.video(
                                        id: content.video.id, language: l10n.language.rawValue, webBaseURL: webBaseURL
                                    ).absoluteString)
                            )
                            .multilineTextAlignment(.center)
                            Button(l10n("common.dismiss")) { showingReport = false }
                        }
                        .padding(60)
                    }
                }
            }
            .task { await model.load(language: l10n.language) }
            .onDisappear { model.player.stop() }
        }
    }
#endif

#if os(iOS) || os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import SwiftUI

    /// The featured video at the top of home: the web's `.home-hero`, a hero card with a gilded border.
    struct HomeHero: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.fanous) private var theme
        let video: Video
        let open: () -> Void

        var body: some View {
            let shape = FanousShape.rounded(theme.radius.xl)
            // The art beside the text where there is room (iPad landscape, Mac), above it on a phone. The art keeps its
            // own colours to its edge: no fade into the page, which in light themes washed it out to a white band.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 0) {
                    art.frame(minWidth: 440, maxWidth: 720)
                    details.frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 0) {
                    art
                    details
                }
            }
            .clipShape(FanousShape.rounded(theme.radius.xl - 1))
            .padding(1)
            .fanousMaterial(.hero, shape)
            .accessibilityIdentifier("home-hero")
        }

        private var art: some View {
            Button(action: open) {
                ThumbnailImage(url: video.thumbnailURL, corners: 0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(video.displayTitle(l10n.language))
        }

        private var details: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                Text(l10n("home.featured")).fanousFont(.caption).fontWeight(.semibold).foregroundStyle(Fanous.link)
                Text(video.displayTitle(l10n.language))
                    .fanousFont(.headline)
                    .foregroundStyle(Fanous.textPrimary)
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    DisplayFormat.meta(
                        [video.displayChannelName(l10n.language), DisplayFormat.views(video.views, l10n)], l10n.language)
                )
                .fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                Button(action: open) { Label(l10n("home.watchNow"), systemImage: "play.fill") }
                    .buttonStyle(FanousButtonStyle(.primary))
                    .padding(.top, FanousScale.spacingSm)
                    .accessibilityIdentifier("hero-watch")
            }
            .padding(FanousScale.spacingLg)
        }
    }

    /// Pure rail list; separate from loading so it can be snapshot-tested.
    struct HomeRailsContent: View {
        let rails: [HomeRail]
        var cardWidth: CGFloat = 260
        let open: (Video) -> Void

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: FanousScale.spacingXl) {
                        if let featured = rails.first?.videos.first {
                            HomeHero(video: featured) { open(featured) }.padding(.horizontal)
                        }
                        // Each rail as a grid of whole cards: one full-width column on a phone, as many as fit on iPad and
                        // Mac. No card is ever cut by the screen or window edge, in either reading direction.
                        ForEach(rails) { rail in
                            VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
                                RailHeader(kind: rail.kind)
                                LazyVGrid(
                                    columns: [
                                        GridItem(.adaptive(minimum: cardWidth), spacing: FanousScale.spacingLg, alignment: .top)
                                    ],
                                    alignment: .leading, spacing: FanousScale.spacingLg
                                ) {
                                    ForEach(rails.cards(of: rail)) { video in
                                        Button {
                                            open(video)
                                        } label: {
                                            VideoCardContent(video: video)
                                        }
                                        .buttonStyle(VideoCardButtonStyle())
                                        .accessibilityIdentifier("video-card-\(rail.kind.rawValue)-\(video.id)")
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .id("rail-\(rail.kind.rawValue)")
                            .accessibilityIdentifier("rail-\(rail.kind.rawValue)")
                        }
                    }
                    .padding(.vertical)
                }
                .scrollsToRequestedSection(proxy, among: rails.map { "rail-\($0.kind.rawValue)" }, ready: !rails.isEmpty)
            }
            .fanousPage()
        }
    }

    /// Skeleton of the hero and one rail, while home loads.
    struct HomeSkeleton: View {
        var body: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingXl) {
                SkeletonBlock(radius: \.xl).aspectRatio(16 / 12, contentMode: .fit)
                SkeletonBlock(radius: \.sm).frame(width: 140, height: 20)
                HStack(spacing: FanousScale.spacingLg) {
                    ForEach(0..<2, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(radius: \.lg).aspectRatio(16 / 9, contentMode: .fit)
                            SkeletonBlock(radius: \.sm).frame(height: 14)
                            SkeletonBlock(radius: \.sm).frame(width: 90, height: 12)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .accessibilityElement()
            .accessibilityIdentifier("home-loading")
        }
    }

    public struct HomeView: View {
        @Environment(\.l10n) private var l10n
        @State private var model: HomeViewModel
        private let open: (Video) -> Void

        public init(catalog: any CatalogServicing, open: @escaping (Video) -> Void) {
            _model = State(initialValue: HomeViewModel(catalog: catalog))
            self.open = open
        }

        public var body: some View {
            Group {
                switch model.state {
                case .loading:
                    HomeSkeleton().accessibilityLabel(l10n("common.loading"))
                case .failed:
                    ErrorStateView { Task { await model.load() } }
                case .loaded(let rails) where rails.isEmpty:
                    EmptyStateView(title: l10n("home.empty"))
                case .loaded(let rails):
                    HomeRailsContent(rails: rails, open: open).refreshable { await model.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fanousPage()
            .task { await model.load() }
        }
    }
#endif

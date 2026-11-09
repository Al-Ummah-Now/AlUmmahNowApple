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
            VStack(alignment: .leading, spacing: 0) {
                Button(action: open) {
                    Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                        .background(Fanous.surfaceRaised)
                        .overlay { FanousMotif(.loader).frame(width: 56, height: 56).opacity(0.35) }
                        .overlay {
                            if let url = video.thumbnailURL {
                                AsyncImage(url: url) { phase in
                                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                                }
                            }
                        }
                        .overlay {
                            LinearGradient(
                                stops: [
                                    .init(color: Color(theme.colors.surfaceRaised).opacity(0.8), location: 0),
                                    .init(color: .clear, location: 0.4),
                                ], startPoint: .bottom, endPoint: .top)
                        }
                        .clipped()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(video.displayTitle(l10n.language))
                VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                    Text(l10n("home.featured")).fanousFont(.caption).fontWeight(.semibold).foregroundStyle(Fanous.link)
                    Text(video.displayTitle(l10n.language))
                        .fanousFont(.headline)
                        .foregroundStyle(Fanous.textPrimary)
                        .lineLimit(3)
                        .accessibilityAddTraits(.isHeader)
                    if let channel = video.channelName {
                        Text(channel).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                    }
                    Button(action: open) { Label(l10n("home.watchNow"), systemImage: "play.fill") }
                        .buttonStyle(FanousButtonStyle(.primary))
                        .padding(.top, FanousScale.spacingSm)
                        .accessibilityIdentifier("hero-watch")
                }
                .padding(FanousScale.spacingLg)
            }
            .clipShape(FanousShape.rounded(theme.radius.xl - 1))
            .padding(1)
            .fanousMaterial(.hero, shape)
            .accessibilityIdentifier("home-hero")
        }
    }

    /// Pure rail list; separate from loading so it can be snapshot-tested.
    struct HomeRailsContent: View {
        let rails: [HomeRail]
        var cardWidth: CGFloat = 260
        let open: (Video) -> Void

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FanousScale.spacingXl) {
                    if let featured = rails.first?.videos.first {
                        HomeHero(video: featured) { open(featured) }.padding(.horizontal)
                    }
                    ForEach(rails) { rail in
                        VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
                            RailHeader(kind: rail.kind).padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: FanousScale.spacingLg) {
                                    ForEach(rail.videos) { video in
                                        Button {
                                            open(video)
                                        } label: {
                                            VideoCardContent(video: video).frame(width: cardWidth)
                                        }
                                        .buttonStyle(VideoCardButtonStyle())
                                        .accessibilityIdentifier("video-card-\(rail.kind.rawValue)-\(video.id)")
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 4)
                            }
                        }
                        .accessibilityIdentifier("rail-\(rail.kind.rawValue)")
                    }
                }
                .padding(.vertical)
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

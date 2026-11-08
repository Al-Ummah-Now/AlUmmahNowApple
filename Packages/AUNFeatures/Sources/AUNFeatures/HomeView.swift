#if os(iOS) || os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import SwiftUI

    /// Pure rail list; separate from loading so it can be snapshot-tested.
    struct HomeRailsContent: View {
        let rails: [HomeRail]
        var cardWidth: CGFloat = 260
        let open: (Video) -> Void

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(rails) { rail in
                        VStack(alignment: .leading, spacing: 10) {
                            RailHeader(kind: rail.kind).padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(rail.videos) { video in
                                        Button {
                                            open(video)
                                        } label: {
                                            VideoCardContent(video: video).frame(width: cardWidth)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("video-card-\(rail.kind.rawValue)-\(video.id)")
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        .accessibilityIdentifier("rail-\(rail.kind.rawValue)")
                    }
                }
                .padding(.vertical)
            }
            .background(Fanous.background)
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
                    ProgressView(l10n("common.loading")).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    ErrorStateView { Task { await model.load() } }
                case .loaded(let rails) where rails.isEmpty:
                    Text(l10n("home.empty")).foregroundStyle(Fanous.textSecondary).frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let rails):
                    HomeRailsContent(rails: rails, open: open).refreshable { await model.load() }
                }
            }
            .background(Fanous.background)
            .task { await model.load() }
        }
    }
#endif

#if os(iOS) || os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import AUNPlayer
    import SwiftUI

    /// Title, description and chapters. Separate from the player so it can be snapshot-tested.
    struct WatchDetails: View {
        @Environment(\.l10n) private var l10n
        let content: WatchContent
        let seek: (Chapter) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(content.video.displayTitle(l10n.language))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Fanous.textPrimary)
                        .accessibilityIdentifier("watch-title")
                    Text(metadata).font(.footnote).foregroundStyle(Fanous.textSecondary)
                }
                let description = content.video.displayDescription(l10n.language)
                if !description.isEmpty {
                    Text(description).font(.body).foregroundStyle(Fanous.textPrimary)
                        .accessibilityIdentifier("watch-description")
                }
                if !content.chapters.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n("watch.chapters")).font(.headline).foregroundStyle(Fanous.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(content.chapters) { chapter in
                            Button {
                                seek(chapter)
                            } label: {
                                HStack {
                                    Text(DisplayFormat.duration(chapter.startTime, l10n.language))
                                        .monospacedDigit()
                                        .foregroundStyle(Fanous.accentText)
                                    Text(chapter.displayTitle(l10n.language)).foregroundStyle(Fanous.textPrimary)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("chapter-\(chapter.id)")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var metadata: String {
            let views = l10n("video.views", DisplayFormat.count(content.video.views, l10n.language))
            return [content.video.channelName, views].compactMap { $0 }.joined(separator: " · ")
        }
    }

    public struct WatchView: View {
        @Environment(\.l10n) private var l10n
        #if os(iOS)
            @Environment(\.horizontalSizeClass) private var sizeClass
        #endif
        @State private var model: WatchViewModel

        public init(videoID: String, catalog: any CatalogServicing) {
            _model = State(initialValue: WatchViewModel(videoID: videoID, catalog: catalog))
        }

        private var usesTwoPanes: Bool {
            #if os(iOS)
                sizeClass == .regular
            #else
                true
            #endif
        }

        public var body: some View {
            Group {
                switch model.state {
                case .loading:
                    ProgressView(l10n("common.loading")).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    ErrorStateView { Task { await model.load(language: l10n.language) } }
                case .loaded(let content):
                    if usesTwoPanes { twoPanes(content) } else { singleColumn(content) }
                }
            }
            .background(Fanous.background)
            .task { await model.load(language: l10n.language) }
            .onDisappear { model.player.stop() }
        }

        @ViewBuilder
        private func playerArea(_ content: WatchContent) -> some View {
            VStack(spacing: 8) {
                if content.video.isPlayable {
                    PlayerSurface(controller: model.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .accessibilityIdentifier("player")
                    if model.player.phase == .failed {
                        Text(l10n("player.error")).font(.footnote).foregroundStyle(Fanous.error)
                            .accessibilityIdentifier("player-error")
                    }
                    PlayerControlsBar(controller: model.player).padding(.horizontal)
                } else {
                    Text(l10n("watch.notReady"))
                        .foregroundStyle(Fanous.textSecondary)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(Fanous.surface)
                        .accessibilityIdentifier("watch-not-ready")
                }
            }
        }

        private func details(_ content: WatchContent) -> some View {
            WatchDetails(content: content) { model.player.seek(to: $0.startTime) }
        }

        private func singleColumn(_ content: WatchContent) -> some View {
            VStack(spacing: 0) {
                playerArea(content)
                ScrollView { details(content).padding() }
            }
        }

        private func twoPanes(_ content: WatchContent) -> some View {
            HStack(alignment: .top, spacing: 0) {
                playerArea(content).frame(maxWidth: .infinity).padding(.top, 8)
                ScrollView { details(content).padding() }.frame(width: 340)
            }
        }
    }
#endif

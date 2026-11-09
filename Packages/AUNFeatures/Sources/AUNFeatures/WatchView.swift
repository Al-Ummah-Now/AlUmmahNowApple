#if os(iOS) || os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import AUNPlayer
    import SwiftUI

    /// Title, description and chapters. Separate from the player so it can be snapshot-tested.
    struct WatchDetails: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.fanous) private var theme
        let content: WatchContent
        let seek: (Chapter) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(content.video.displayTitle(l10n.language))
                        .fanousFont(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(Fanous.textPrimary)
                        .accessibilityIdentifier("watch-title")
                    Text(metadata).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                }
                let description = content.video.displayDescription(l10n.language)
                if !description.isEmpty {
                    Text(description).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(FanousScale.spacingLg)
                        .fanousMaterial(.card) { .rounded($0.lg) }
                        .accessibilityIdentifier("watch-description")
                }
                if !content.chapters.isEmpty { chapters }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var chapters: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                Text(l10n("watch.chapters")).fanousFont(.label).fontWeight(.bold).foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(content.chapters.enumerated()), id: \.element.id) { index, chapter in
                        if index > 0 { Rectangle().fill(Fanous.divider).frame(height: 1).padding(.horizontal, 12) }
                        Button {
                            seek(chapter)
                        } label: {
                            HStack(spacing: FanousScale.spacingMd) {
                                Text(DisplayFormat.duration(chapter.startTime, l10n.language))
                                    .fanousFont(.caption)
                                    .monospacedDigit()
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Fanous.link)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .fanousMaterial(.control) { .rounded($0.sm) }
                                Text(chapter.displayTitle(l10n.language)).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(ChapterRowStyle())
                        .accessibilityIdentifier("chapter-\(chapter.id)")
                    }
                }
                .clipShape(FanousShape.rounded(theme.radius.lg))
                .fanousMaterial(.card) { .rounded($0.lg) }
            }
        }

        private var metadata: String {
            let views = l10n("video.views", DisplayFormat.count(content.video.views, l10n.language))
            return [content.video.channelName, views].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// A chapter row takes the hover material while pressed.
    private struct ChapterRowStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.background { if configuration.isPressed { FanousSurfaceKind(kind: .hover, shape: .rect) } }
        }
    }

    /// One clip for the picture and its chrome, in the theme's radius, with the page's player ring and glow.
    struct PlayerClip<Picture: View>: View {
        @Environment(\.fanous) private var theme
        @ViewBuilder let picture: Picture

        var body: some View {
            let shape = FanousShape.rounded(theme.radius.lg)
            picture
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(shape)
                .background {
                    FanousSurface(fills: [], shadows: theme.material.player + theme.material.playerRing, shape: shape)
                }
                .overlay { FanousSurface(fills: [], shadows: theme.material.playerInner, shape: shape) }
                .accessibilityIdentifier("player")
        }
    }

    struct PlayerFrame: View {
        let controller: PlayerController

        var body: some View { PlayerClip { PlayerSurface(controller: controller) } }
    }

    /// The chrome over a still frame instead of the live picture, for snapshots: a night scene with lantern lights,
    /// so the bar is judged over bright and dark video at once.
    struct PlayerSnapshotFrame: View {
        let controller: PlayerController
        let menu: PlayerMenu?

        var body: some View {
            PlayerClip {
                ZStack {
                    Canvas { context, size in
                        context.fill(
                            Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.06, green: 0.07, blue: 0.12)))
                        let lights: [(CGFloat, CGFloat, CGFloat, Color)] = [
                            (0.18, 0.3, 0.35, .orange), (0.55, 0.2, 0.3, .purple), (0.82, 0.45, 0.28, .green),
                            (0.4, 0.75, 0.4, Color(red: 1, green: 0.85, blue: 0.6)),
                        ]
                        for (x, y, r, color) in lights {
                            let center = CGPoint(x: size.width * x, y: size.height * y)
                            context.fill(
                                Path(CGRect(origin: .zero, size: size)),
                                with: .radialGradient(
                                    Gradient(colors: [color.opacity(0.85), .clear]), center: center, startRadius: 0,
                                    endRadius: size.width * r))
                        }
                    }
                    PlayerChrome(controller: controller, menu: menu)
                }
            }
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
                    ThemeLoader()
                case .failed:
                    ErrorStateView { Task { await model.load(language: l10n.language) } }
                case .loaded(let content):
                    if usesTwoPanes { twoPanes(content) } else { singleColumn(content) }
                }
            }
            .fanousPage()
            .task { await model.load(language: l10n.language) }
            #if os(iOS)
                .fullScreenCover(
                    isPresented: Binding(get: { model.player.isFullscreen }, set: { model.player.isFullscreen = $0 })
                ) {
                    PlayerSurface(controller: model.player).ignoresSafeArea().preferredColorScheme(.dark)
                    .persistentSystemOverlays(.hidden)
                }
            #elseif os(macOS)
                .onChange(of: model.player.isFullscreen) { _, _ in NSApp.keyWindow?.toggleFullScreen(nil) }
            #endif
            .onDisappear { model.player.stop() }
            #if os(macOS)
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    model.player.togglePlayback()
                    return .handled
                }
                .onKeyPress(.leftArrow) { skip(isRightArrow: false) }
                .onKeyPress(.rightArrow) { skip(isRightArrow: true) }
            #endif
        }

        #if os(macOS)
            @Environment(\.layoutDirection) private var direction

            private func skip(isRightArrow: Bool) -> KeyPress.Result {
                model.player.skip(by: SkipKey.delta(isRightArrow: isRightArrow, direction: direction))
                return .handled
            }
        #endif

        @ViewBuilder
        private func playerArea(_ content: WatchContent) -> some View {
            VStack(spacing: 8) {
                if content.video.isPlayable {
                    PlayerFrame(controller: model.player).padding(.horizontal, usesTwoPanes ? 16 : 12)
                } else {
                    VStack(spacing: 12) {
                        FanousMotif(.loader).frame(width: 44, height: 44)
                        Text(l10n("watch.notReady")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .fanousMaterial(.hero) { .rounded($0.lg) }
                    .padding(.horizontal)
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

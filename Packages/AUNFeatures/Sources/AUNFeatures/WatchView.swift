#if os(iOS) || os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import AUNPlayer
    import SwiftUI

    /// Title, description and chapters. Separate from the player so it can be snapshot-tested.
    struct WatchDetails: View {
        @Environment(\.l10n) private var l10n
        let content: WatchContent
        /// Off where the page shows the chapters elsewhere (under the player, beside these details).
        var showsChapters = true
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
                if showsChapters, !content.chapters.isEmpty { ChapterList(chapters: content.chapters, seek: seek) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var metadata: String {
            let views = DisplayFormat.views(content.video.views, l10n)
            return DisplayFormat.meta([content.video.displayChannelName(l10n.language), views], l10n.language)
        }
    }

    /// The chapters card: each row starts with its time (the leading edge, the right in Arabic) and seeks there.
    struct ChapterList: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.fanous) private var theme
        let chapters: [Chapter]
        let seek: (Chapter) -> Void

        private var widestStart: String {
            chapters.map { DisplayFormat.duration($0.startTime, l10n.language) }.max { $0.count < $1.count } ?? ""
        }

        var body: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                Text(l10n("watch.chapters")).fanousFont(.label).fontWeight(.bold).foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        if index > 0 { Rectangle().fill(Fanous.divider).frame(height: 1).padding(.horizontal, 12) }
                        Button {
                            seek(chapter)
                        } label: {
                            HStack(spacing: FanousScale.spacingMd) {
                                // Every badge is as wide as the longest start time, so the titles form one column.
                                ZStack {
                                    Text(widestStart).hidden()
                                    Text(DisplayFormat.duration(chapter.startTime, l10n.language))
                                }
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A chapter row takes the hover material while pressed.
    private struct ChapterRowStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.background { if configuration.isPressed { FanousSurfaceKind(kind: .hover, shape: .rect) } }
        }
    }

    /// "Up next": other videos as cards, as many columns as fit, each opening its own watch page.
    struct UpNextSection: View {
        @Environment(\.l10n) private var l10n
        let videos: [Video]
        let open: (Video) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
                Text(l10n("watch.upNext")).fanousFont(.title).fontWeight(.bold).foregroundStyle(Fanous.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: FanousScale.spacingLg, alignment: .top)],
                    alignment: .leading, spacing: FanousScale.spacingLg
                ) {
                    ForEach(videos) { video in
                        Button {
                            open(video)
                        } label: {
                            VideoCardContent(video: video)
                        }
                        .buttonStyle(VideoCardButtonStyle())
                        .accessibilityIdentifier("up-next-\(video.id)")
                    }
                }
            }
            .accessibilityIdentifier("watch-up-next")
        }
    }

    public struct WatchView: View {
        @Environment(\.l10n) private var l10n
        #if os(iOS)
            @Environment(\.horizontalSizeClass) private var sizeClass
        #endif
        @State private var model: WatchViewModel
        private let open: (String) -> Void

        /// `open` shows another video's page, from "Up next".
        public init(videoID: String, catalog: any CatalogServicing, open: @escaping (String) -> Void = { _ in }) {
            _model = State(initialValue: WatchViewModel(videoID: videoID, catalog: catalog))
            self.open = open
        }

        /// The player beside the details when both fit side by side. iPad: only in landscape (an 11-inch iPad in
        /// portrait is 1032 points wide, so width alone is not enough), so portrait stacks them and the page below the
        /// player is never left empty. Mac: whenever the 340-point details column leaves the player a usable width, so
        /// the title, the channel row and the chapters are on screen beside the player, never under the fold.
        private func usesTwoPanes(_ size: CGSize) -> Bool {
            #if os(iOS)
                return sizeClass == .regular && size.width >= 1000 && size.width > size.height
            #else
                return size.width >= 720
            #endif
        }

        /// Store screenshots (`-AUNFixturePlayable YES`) open the page before playback, on the video's poster.
        private static let opensOnPoster = UserDefaults.standard.bool(forKey: "AUNFixturePlayable")

        public var body: some View {
            Group {
                switch model.state {
                case .loading:
                    ThemeLoader()
                case .failed:
                    ErrorStateView { Task { await model.load(language: l10n.language) } }
                case .loaded(let content):
                    GeometryReader { geometry in
                        if usesTwoPanes(geometry.size) {
                            twoPanes(content)
                        } else if sizeIsCompact {
                            singleColumn(content)
                        } else {
                            stacked(content)
                        }
                    }
                }
            }
            .fanousPage()
            .task { await model.load(language: l10n.language, autoplay: !Self.opensOnPoster) }
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
                    PlayerSurface(controller: model.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { if showsPoster { poster(content.video) } }
                        .accessibilityIdentifier("player")
                    if model.player.phase == .failed {
                        Text(l10n("player.error")).font(.footnote).foregroundStyle(Fanous.errorText)
                            .accessibilityIdentifier("player-error")
                    }
                    PlayerControlsBar(controller: model.player, knownDuration: content.video.durationSeconds)
                        .padding(.horizontal)
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

        /// Until playback starts the player shows the video's thumbnail, never an empty rectangle.
        private var showsPoster: Bool {
            !model.player.isPlaying && model.player.currentTime < 0.05 && model.player.phase != .failed
        }

        private func poster(_ video: Video) -> some View {
            Button {
                model.player.togglePlayback()
            } label: {
                ThumbnailImage(url: video.thumbnailURL, corners: 0)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Fanous.onPrimary)
                            .frame(width: 72, height: 72)
                            .fanousMaterial(.primary, .circle)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n("player.play"))
            .accessibilityIdentifier("player-poster")
        }

        private var sizeIsCompact: Bool {
            #if os(iOS)
                sizeClass != .regular
            #else
                false
            #endif
        }

        private func details(_ content: WatchContent, showsChapters: Bool = true) -> some View {
            WatchDetails(content: content, showsChapters: showsChapters) { model.player.seek(to: $0.startTime) }
        }

        @ViewBuilder
        private func upNext(_ content: WatchContent) -> some View {
            if !content.upNext.isEmpty { UpNextSection(videos: content.upNext) { open($0.id) } }
        }

        private func singleColumn(_ content: WatchContent) -> some View {
            VStack(spacing: 0) {
                playerArea(content)
                ScrollView {
                    VStack(spacing: FanousScale.spacingXl) {
                        details(content)
                        upNext(content)
                    }
                    .padding()
                }
            }
        }

        /// iPad in portrait: the player right under the header, then the details and "Up next", in one scrolling page.
        private func stacked(_ content: WatchContent) -> some View {
            ScrollView {
                VStack(spacing: FanousScale.spacingMd) {
                    playerArea(content)
                    VStack(spacing: FanousScale.spacingXl) {
                        details(content)
                        upNext(content)
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom)
            }
        }

        /// Mac and iPad in landscape: the player with its chapters under it, and beside them the title, description and
        /// "Up next". Both columns reach the bottom of the window, and the title, channel row, description and chapters
        /// are all on screen without scrolling.
        private func twoPanes(_ content: WatchContent) -> some View {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(spacing: FanousScale.spacingLg) {
                        playerArea(content)
                        if !content.chapters.isEmpty {
                            ChapterList(chapters: content.chapters) { model.player.seek(to: $0.startTime) }
                                .padding(.horizontal)
                        }
                    }
                    .padding(.bottom)
                }
                .frame(maxWidth: .infinity)
                ScrollView {
                    VStack(spacing: FanousScale.spacingXl) {
                        details(content, showsChapters: false)
                        upNext(content)
                    }
                    .padding()
                }
                .frame(width: 340)
            }
        }
    }
#endif

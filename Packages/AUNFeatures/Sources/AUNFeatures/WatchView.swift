#if os(iOS) || os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import AUNPlayer
    import SwiftUI
    #if os(iOS)
        import UIKit
    #else
        import AppKit
    #endif

    /// Title, description and chapters. Separate from the player so it can be snapshot-tested.
    struct WatchDetails: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.fanous) private var theme
        @State private var confirmBlockChannel = false
        @State private var linkCopied = false
        let content: WatchContent
        let webBaseURL: URL
        var share: (() -> URL?)?
        let seek: (Chapter) -> Void

        private var blockStore: ViewerBlockStore { .shared }
        private var channelName: String? { content.video.channelName }
        private var channelID: String? {
            let trimmed = content.video.channelID?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        private var blockLabel: String? {
            if let channelName, !channelName.isEmpty { return channelName }
            return channelID != nil ? l10n("safety.blockedList.kind.channel") : nil
        }
        private var isBlocked: Bool { blockStore.isChannelBlocked(id: content.video.channelID, name: channelName) }

        var body: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                HStack(alignment: .top, spacing: FanousScale.spacingSm) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(content.video.displayTitle(l10n.language))
                            .fanousFont(.title)
                            .fontWeight(.bold)
                            .foregroundStyle(Fanous.textPrimary)
                            .accessibilityIdentifier("watch-title")
                        Text(metadata).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        if let share {
                            Button {
                                guard let url = share() else { return }
                                #if os(iOS)
                                    UIPasteboard.general.string = url.absoluteString
                                #else
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                #endif
                                linkCopied = true
                            } label: {
                                Label(l10n("watch.copyLink"), systemImage: "link")
                            }
                            .accessibilityIdentifier("watch-copy-link")
                        }
                        Link(
                            destination: ViewerReportURL.video(
                                id: content.video.id, language: l10n.language.rawValue, webBaseURL: webBaseURL)
                        ) {
                            Label(l10n("safety.report.video"), systemImage: "flag")
                        }
                        .accessibilityIdentifier("report-video")
                        if let channelID {
                            Link(
                                destination: ViewerReportURL.channel(
                                    id: channelID, language: l10n.language.rawValue, webBaseURL: webBaseURL)
                            ) {
                                Label(l10n("safety.report.channel"), systemImage: "flag")
                            }
                            .accessibilityIdentifier("report-channel")
                        }
                        if blockLabel != nil, !isBlocked {
                            Button {
                                confirmBlockChannel = true
                            } label: {
                                Label(l10n("safety.block.channel"), systemImage: "hand.raised.slash")
                            }
                            .accessibilityIdentifier("block-channel")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(Fanous.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel(l10n("safety.moreActions"))
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("watch-actions-menu")
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
            .alert(l10n("watch.linkCopied"), isPresented: $linkCopied) {
                Button(l10n("common.dismiss"), role: .cancel) {}
            }
            .sheet(isPresented: $confirmBlockChannel) {
                if let label = blockLabel {
                    ViewerBlockConfirmSheet(
                        title: l10n("safety.block.channelTitle", label),
                        message: l10n("safety.block.channelMessage")
                    ) {
                        blockStore.blockChannel(id: content.video.channelID, name: channelName ?? "")
                    }
                }
            }
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
            let views = DisplayFormat.views(content.video.views, l10n)
            return DisplayFormat.meta([content.video.channelName, views], l10n.language)
        }
    }

    /// A chapter row takes the hover material while pressed.
    private struct ChapterRowStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.background { if configuration.isPressed { FanousSurfaceKind(kind: .hover, shape: .rect) } }
        }
    }

    public struct WatchView: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        #if os(iOS)
            @Environment(\.horizontalSizeClass) private var sizeClass
        #endif
        @State private var model: WatchViewModel
        private let webBaseURL: URL
        private let siteOrigin: URL

        public init(videoID: String, catalog: any CatalogServicing, webBaseURL: URL, siteOrigin: URL? = nil) {
            _model = State(initialValue: WatchViewModel(videoID: videoID, catalog: catalog))
            self.webBaseURL = webBaseURL
            self.siteOrigin = siteOrigin ?? webBaseURL
        }

        private var blockStore: ViewerBlockStore { .shared }

        private func isChannelBlocked(_ content: WatchContent) -> Bool {
            blockStore.isChannelBlocked(id: content.video.channelID, name: content.video.channelName)
        }

        private var usesTwoPanes: Bool {
            #if os(iOS)
                sizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
            #else
                true
            #endif
        }

        public var body: some View {
            let blocked: Bool = {
                if case .loaded(let content) = model.state { return isChannelBlocked(content) }
                return false
            }()
            Group {
                switch model.state {
                case .loading:
                    ThemeLoader()
                case .failed:
                    ErrorStateView { Task { await model.load(language: l10n.language) } }
                case .loaded(let content):
                    if isChannelBlocked(content) {
                        blockedPage(content)
                    } else if usesTwoPanes {
                        twoPanes(content)
                    } else {
                        singleColumn(content)
                    }
                }
            }
            .fanousPage()
            .task { await model.load(language: l10n.language) }
            .onChange(of: blocked, initial: true) { _, nowBlocked in
                if nowBlocked { model.holdBack() }
            }
            .onChange(of: model.isHeldBack && !blocked, initial: true) { _, isFree in
                if isFree { Task { await model.load(language: l10n.language) } }
            }
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
            private func skip(isRightArrow: Bool) -> KeyPress.Result {
                model.player.skip(by: SkipKey.delta(isRightArrow: isRightArrow))
                return .handled
            }
        #endif

        /// Blocked watch page: hides title, description, chapters and player, showing only the report menu and one Unblock card.
        private func blockedPage(_ content: WatchContent) -> some View {
            let displayName = content.video.channelName ?? l10n("safety.blockedList.kind.channel")
            let channelID = content.video.channelID?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ScrollView {
                VStack(spacing: FanousScale.spacingLg) {
                    HStack {
                        Spacer(minLength: 0)
                        Menu {
                            Link(
                                destination: ViewerReportURL.video(
                                    id: content.video.id, language: l10n.language.rawValue, webBaseURL: webBaseURL)
                            ) {
                                Label(l10n("safety.report.video"), systemImage: "flag")
                            }
                            .accessibilityIdentifier("report-video")
                            if let channelID, !channelID.isEmpty {
                                Link(
                                    destination: ViewerReportURL.channel(
                                        id: channelID, language: l10n.language.rawValue, webBaseURL: webBaseURL)
                                ) {
                                    Label(l10n("safety.report.channel"), systemImage: "flag")
                                }
                                .accessibilityIdentifier("report-channel")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(Fanous.textSecondary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                                .accessibilityLabel(l10n("safety.moreActions"))
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("watch-actions-menu")
                    }
                    .padding(.bottom, 4)
                    BlockedChannelCard(
                        channelDisplayName: displayName,
                        cardIdentifier: "watch-channel-blocked",
                        unblockIdentifier: "watch-unblock-channel"
                    ) {
                        blockStore.unblockChannel(id: content.video.channelID, name: content.video.channelName)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
        }

        @ViewBuilder
        private func playerArea(_ content: WatchContent) -> some View {
            VStack(spacing: 8) {
                if content.video.isPlayable {
                    PlayerSurface(controller: model.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .accessibilityIdentifier("player")
                    if model.player.phase == .failed {
                        Text(l10n("player.error")).font(.footnote).foregroundStyle(Fanous.errorText)
                            .accessibilityIdentifier("player-error")
                    }
                    PlayerControlsBar(controller: model.player).padding(.horizontal)
                } else {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            notReadyContent
                        } else {
                            notReadyContent.aspectRatio(16 / 9, contentMode: .fit)
                        }
                    }
                    .fanousMaterial(.hero) { .rounded($0.lg) }
                    .padding(.horizontal)
                    .accessibilityIdentifier("watch-not-ready")
                }
            }
        }

        private var notReadyContent: some View {
            VStack(spacing: 12) {
                FanousMotif(.loader).frame(width: 44, height: 44)
                Text(l10n("watch.notReady")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }

        private func details(_ content: WatchContent) -> some View {
            let video = content.video
            let share: (() -> URL?)? = video.isPlayable && !video.isPrivate ? { shareURL(for: video) } : nil
            return WatchDetails(content: content, webBaseURL: webBaseURL, share: share) { model.player.seek(to: $0.startTime) }
        }

        private func shareURL(for video: Video) -> URL? {
            let route = video.isShort ? "shorts" : "video"
            let target: ShortLinks.Target = video.isShort ? .short(video.id) : .video(video.id)
            let page = webBaseURL.appending(path: "/\(l10n.language.rawValue)/\(route)").appending(component: video.id)
            let time = Int(exactly: model.player.currentTime.rounded(.down))
            var fallback = URLComponents(url: page, resolvingAgainstBaseURL: false)
            if !video.isShort, let time, time > 0 {
                fallback?.queryItems = [URLQueryItem(name: "t", value: String(time))]
            }
            return ShortLinks.shareURL(
                for: target, siteOrigin: siteOrigin, fallback: fallback?.url ?? page, language: l10n.language,
                isPrivate: video.isPrivate, startSeconds: time)
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

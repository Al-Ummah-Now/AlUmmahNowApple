import AUNCoreBridge
import AUNDesign
import AUNPlayer
import SwiftUI

#if os(iOS) || os(macOS)
    /// Every stream on air and coming, with the event filter while event tags are on.
    public struct LiveListView: View {
        @Environment(\.l10n) private var l10n
        @State private var model: LiveListModel
        private let open: (LiveStream) -> Void

        public init(live: any LiveServicing, open: @escaping (LiveStream) -> Void) {
            _model = State(initialValue: LiveListModel(live: live))
            self.open = open
        }

        public var body: some View {
            Group {
                switch model.state {
                case .loading: ThemeLoader()
                case .failed: ErrorStateView { Task { await model.load() } }
                case .loaded:
                    let blockStore = ViewerBlockStore.shared
                    LiveListContent(
                        onAir: blockStore.filterLiveStreams(model.onAir),
                        coming: blockStore.filterLiveStreams(model.coming),
                        hasEvents: model.hasEvents, event: model.event,
                        choose: { event in Task { await model.choose(event) } }, open: open
                    )
                    .refreshable { await model.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fanousPage()
            .navigationTitle(l10n("live.title"))
            .task { await model.load() }
        }
    }

    /// Pure list, separate from loading so it can be snapshot-tested.
    struct LiveListContent: View {
        @Environment(\.l10n) private var l10n
        let onAir: [LiveStream]
        let coming: [LiveStream]
        let hasEvents: Bool
        let event: LiveEventType?
        let choose: (LiveEventType?) -> Void
        let open: (LiveStream) -> Void

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: FanousScale.spacingXl) {
                    if hasEvents { filter }
                    if onAir.isEmpty && coming.isEmpty { EmptyStateView(title: l10n("live.empty")) }
                    section("live.onAir", onAir)
                    section("live.coming", coming)
                }
                .padding(.vertical)
            }
        }

        /// One menu, so no choice is cut at the screen's edge.
        private var filter: some View {
            Menu {
                Picker(l10n("live.event.filter"), selection: Binding(get: { event }, set: { choose($0) })) {
                    Text(l10n("live.event.all")).tag(LiveEventType?.none)
                    ForEach(LiveEventType.allCases, id: \.self) { value in
                        Text(l10n("live.event.\(value.rawValue)")).tag(LiveEventType?.some(value))
                    }
                }
            } label: {
                Label(
                    l10n("live.event.chosen", l10n("live.event.\(event?.rawValue ?? "all")")),
                    systemImage: "line.3.horizontal.decrease")
            }
            .buttonStyle(FanousButtonStyle(.secondary))
            .padding(.horizontal)
            .accessibilityIdentifier("live-event-menu")
        }

        @ViewBuilder private func section(_ title: String, _ streams: [LiveStream]) -> some View {
            if !streams.isEmpty {
                VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
                    Text(l10n(title)).fanousFont(.title).fontWeight(.bold).foregroundStyle(Fanous.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: FanousScale.spacingLg)], alignment: .leading,
                        spacing: FanousScale.spacingXl
                    ) {
                        ForEach(streams) { stream in
                            Button {
                                open(stream)
                            } label: {
                                LiveCardContent(stream: stream)
                            }
                            .buttonStyle(VideoCardButtonStyle())
                            .accessibilityIdentifier("live-card-\(stream.id)")
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    public struct LiveWatchView: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.scenePhase) private var scenePhase
        /// Wide enough for the chat beside the player: landscape iPad and Mac windows. A portrait iPad of any size has it
        /// under the player.
        private static let twoPaneWidth: CGFloat = 960
        @State private var model: LiveWatchModel
        private let webBaseURL: URL

        public init(streamID: String, core: CoreBridge) {
            _model = State(initialValue: LiveWatchModel(streamID: streamID, live: core.live, catalog: core.catalog))
            webBaseURL = core.environment.webBaseURL
        }

        private var blockStore: ViewerBlockStore { .shared }

        private func isChannelBlocked(_ content: LiveContent) -> Bool {
            blockStore.isChannelBlocked(id: content.stream.channelID, name: content.stream.channelName)
        }

        public var body: some View {
            let blocked: Bool = {
                if case .loaded(let content) = model.state { return isChannelBlocked(content) }
                return false
            }()
            Group {
                switch model.state {
                case .loading: ThemeLoader()
                case .failed: ErrorStateView { Task { await model.load(language: l10n.language) } }
                case .loaded(let content):
                    GeometryReader { geometry in page(content, size: geometry.size) }
                }
            }
            .fanousPage()
            .task { await model.load(language: l10n.language) }
            // Nothing is asked for in the background, also while the sound plays on there
            .onAppear { model.setActive(scenePhase != .background) }
            .onChange(of: scenePhase) { model.setActive(scenePhase != .background) }
            .onChange(of: blocked, initial: true) { _, nowBlocked in
                model.setBlocked(nowBlocked)
            }
            .onDisappear { model.close() }
        }

        @ViewBuilder private func page(_ content: LiveContent, size: CGSize) -> some View {
            if size.width >= Self.twoPaneWidth, size.width > size.height, content.hasChat, !isChannelBlocked(content) {
                HStack(alignment: .top, spacing: FanousScale.spacingLg) {
                    ScrollView { main(content) }
                    chat(content).frame(width: 340).frame(maxHeight: .infinity)
                }
                .padding()
            } else {
                ScrollView {
                    VStack(spacing: FanousScale.spacingLg) {
                        main(content)
                        if content.hasChat, !isChannelBlocked(content) { chat(content).frame(height: 420) }
                    }
                    .padding()
                }
            }
        }

        private func chat(_ content: LiveContent) -> some View {
            LiveChatView(
                streamID: content.stream.id, webBaseURL: webBaseURL, messages: model.messages, pinned: model.pinned,
                isReplay: content.mode == .recording)
        }

        private func main(_ content: LiveContent) -> some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
                if isChannelBlocked(content) {
                    let displayName = content.stream.channelName ?? l10n("safety.blockedList.kind.channel")
                    let channelID = content.stream.channelID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    HStack {
                        Spacer(minLength: 0)
                        Menu {
                            Link(
                                destination: ViewerReportURL.liveStream(
                                    id: content.stream.id, language: l10n.language.rawValue, webBaseURL: webBaseURL)
                            ) {
                                Label(l10n("safety.report.stream"), systemImage: "flag")
                            }
                            .accessibilityIdentifier("report-live-stream")
                            if let channelID, !channelID.isEmpty {
                                Link(
                                    destination: ViewerReportURL.channel(
                                        id: channelID, language: l10n.language.rawValue, webBaseURL: webBaseURL)
                                ) {
                                    Label(l10n("safety.report.channel"), systemImage: "flag")
                                }
                                .accessibilityIdentifier("report-live-channel")
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
                        .accessibilityIdentifier("live-actions-menu")
                    }
                    .padding(.bottom, 4)
                    BlockedChannelCard(
                        channelDisplayName: displayName,
                        cardIdentifier: "live-channel-blocked",
                        unblockIdentifier: "live-unblock-channel"
                    ) {
                        blockStore.unblockChannel(id: content.stream.channelID, name: content.stream.channelName)
                    }
                } else {
                    if content.mode == .live || content.mode == .recording {
                        PlayerSurface(controller: model.player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .accessibilityIdentifier("player")
                        if model.player.phase == .failed {
                            Text(l10n("player.error")).font(.footnote).foregroundStyle(Fanous.errorText)
                                .accessibilityIdentifier("player-error")
                        }
                        if model.isBehind {
                            Button(l10n("live.return")) { model.returnToLive() }
                                .buttonStyle(FanousButtonStyle(.secondary))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityIdentifier("live-return")
                        }
                    } else {
                        LiveNotice(content: content, untilStart: model.untilStart)
                    }
                    LiveDetails(content: content, viewers: model.viewers, webBaseURL: webBaseURL)
                }
            }
        }
    }
#endif

#if os(tvOS)
    /// Full screen; the chat is beside it, for reading and reporting.
    struct TVLiveWatchView: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.scenePhase) private var scenePhase
        @State private var model: LiveWatchModel
        private let webBaseURL: URL

        init(streamID: String, core: CoreBridge) {
            _model = State(initialValue: LiveWatchModel(streamID: streamID, live: core.live, catalog: core.catalog))
            self.webBaseURL = core.environment.webBaseURL
        }

        private func openStreamReport(_ stream: LiveStream) {
            model.report(.liveStream(id: stream.id, language: l10n.language.rawValue, webBaseURL: webBaseURL))
        }

        private func openMessageReport(streamID: String, message: LiveChatMessage) {
            model.report(
                .liveChat(
                    streamID: streamID, messageID: message.id, language: l10n.language.rawValue, webBaseURL: webBaseURL))
        }

        var body: some View {
            ZStack {
                Rectangle().fill(Fanous.background).ignoresSafeArea()
                switch model.state {
                case .loading: ProgressView(l10n("common.loading"))
                case .failed: ErrorStateView { Task { await model.load(language: l10n.language) } }
                case .loaded(let content):
                    HStack(alignment: .top, spacing: 40) {
                        VStack(alignment: .leading, spacing: 24) {
                            if content.mode == .live || content.mode == .recording {
                                PlayerSurface(
                                    controller: model.player,
                                    reportTitle: l10n("safety.report.stream"),
                                    reportIdentifier: "tv-report-stream-transport"
                                ) {
                                    openStreamReport(content.stream)
                                }
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .accessibilityIdentifier("player")
                            } else {
                                LiveNotice(content: content, untilStart: model.untilStart)
                            }
                            HStack(spacing: 20) {
                                if model.isBehind, content.mode == .live || content.mode == .recording {
                                    Button {
                                        model.returnToLive()
                                    } label: {
                                        Text(l10n("live.return")).font(.callout.weight(.semibold))
                                    }
                                    .buttonStyle(FanousButtonStyle(.secondary))
                                    .accessibilityIdentifier("live-return")
                                }
                                Button {
                                    openStreamReport(content.stream)
                                } label: {
                                    Label(l10n("safety.report.stream"), systemImage: "flag").font(.callout.weight(.semibold))
                                }
                                .buttonStyle(FanousButtonStyle(.secondary))
                                .accessibilityIdentifier("tv-report-stream")
                            }
                            LiveDetails(content: content, viewers: model.viewers, webBaseURL: webBaseURL)
                            Spacer(minLength: 0)
                        }
                        if content.hasChat {
                            LiveChatView(
                                streamID: content.stream.id, webBaseURL: webBaseURL, messages: model.messages,
                                pinned: model.pinned, isReplay: content.mode == .recording,
                                onReportMessage: { openMessageReport(streamID: content.stream.id, message: $0) }
                            )
                            .frame(width: 480)
                        }
                    }
                    .padding(60)
                    .fullScreenCover(
                        item: Binding(get: { model.reportRequest }, set: { if $0 == nil { model.reportClosed() } })
                    ) { request in
                        TVReportPage(request: request) { model.reportClosed() }
                    }
                }
            }
            .task { await model.load(language: l10n.language) }
            // Nothing is asked for in the background, also while the sound plays on there
            .onAppear { model.setActive(scenePhase != .background) }
            .onChange(of: scenePhase) { model.setActive(scenePhase != .background) }
            .onDisappear { model.close() }
        }
    }
#endif

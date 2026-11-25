import AUNCoreBridge
import AUNDesign
import SwiftUI

/// A small label beside a title or on a card: Live, Premiere, an event tag.
struct LiveTag: View {
    let text: String
    var isLive = false

    var body: some View {
        Text(text)
            .fanousFont(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(isLive ? Fanous.part(\.badgeLiveText) : Fanous.part(\.buttonSecondaryText))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background { if isLive { FanousShape.capsule.fill(Fanous.part(\.badgeLiveBg)) } }
            .overlay { if !isLive { FanousShape.capsule.strokeBorder(Fanous.outline, lineWidth: 1) } }
    }
}

/// What a stream is beside its status. Nothing for a plain live stream.
struct LiveTags: View {
    @Environment(\.l10n) private var l10n
    let kind: LiveKind
    let event: LiveEventType?
    var isLive = false

    var body: some View {
        // One row, or one under the other when large text makes them wider than the card
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { tags }
            VStack(alignment: .leading, spacing: 6) { tags }
        }
    }

    @ViewBuilder private var tags: some View {
        Group {
            if isLive { LiveTag(text: l10n("live.now"), isLive: true).accessibilityIdentifier("live-tag-now") }
            if kind == .premiere { LiveTag(text: l10n("live.premiere")).accessibilityIdentifier("live-tag-premiere") }
            if let event { LiveTag(text: l10n("live.event.\(event.rawValue)")).accessibilityIdentifier("live-tag-event") }
        }
    }
}

/// A stream in a list: as a video's card, with what it is and when.
struct LiveCardContent: View {
    @Environment(\.l10n) private var l10n
    let stream: LiveStream

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailImage(url: stream.thumbnailURL)
            VStack(alignment: .leading, spacing: 5) {
                Text(stream.title)
                    .fanousFont(.label).fontWeight(.semibold)
                    .foregroundStyle(Fanous.part(\.cardVideoTitle))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if hasTags { LiveTags(kind: stream.kind, event: stream.eventType, isLive: stream.status == .live) }
                Text(DisplayFormat.meta([stream.channelName, when], l10n.language))
                    .fanousFont(.caption)
                    .foregroundStyle(Fanous.part(\.cardVideoMeta))
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasTags: Bool { stream.status == .live || stream.kind == .premiere || stream.eventType != nil }

    private var when: String? {
        if stream.status == .live { return stream.viewers.map { l10n("live.watching", DisplayFormat.number($0, l10n.language)) } }
        return stream.scheduledStart.map { DisplayFormat.dateTime($0, l10n.language) }
    }
}

/// The live rail of home: on air first, then coming.
struct LiveRail: View {
    @Environment(\.l10n) private var l10n
    let streams: [LiveStream]
    var cardWidth: CGFloat = 260
    let open: (LiveStream) -> Void
    let seeAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
            HStack {
                Text(l10n("live.title")).fanousFont(.title).fontWeight(.bold).foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let seeAll {
                    Button(l10n("live.seeAll"), action: seeAll).buttonStyle(.plain).fanousFont(.label)
                        .foregroundStyle(Fanous.link).accessibilityIdentifier("live-see-all")
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: FanousScale.spacingLg) {
                    ForEach(streams) { stream in
                        Button {
                            open(stream)
                        } label: {
                            LiveCardContent(stream: stream).frame(width: cardWidth)
                        }
                        .buttonStyle(VideoCardButtonStyle())
                        .accessibilityIdentifier("live-card-\(stream.id)")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rail-live")
    }
}

/// The messages beside a stream, or as they were beside its recording. Reading only.
struct LiveChatView: View {
    @Environment(\.l10n) private var l10n
    @State private var blockingMessage: LiveChatMessage?
    #if os(tvOS)
        @FocusState private var focusedMessage: String?
    #endif
    let streamID: String
    let webBaseURL: URL
    let messages: [LiveChatMessage]
    let pinned: LiveChatMessage?
    let isReplay: Bool
    let onReportMessage: ((LiveChatMessage) -> Void)?

    init(
        streamID: String = "", webBaseURL: URL,
        messages: [LiveChatMessage], pinned: LiveChatMessage?, isReplay: Bool,
        onReportMessage: ((LiveChatMessage) -> Void)? = nil
    ) {
        self.streamID = streamID
        self.webBaseURL = webBaseURL
        self.messages = messages
        self.pinned = pinned
        self.isReplay = isReplay
        self.onReportMessage = onReportMessage
    }

    private var blockStore: ViewerBlockStore { .shared }
    /// The remote is on a message: a new one does not take the list away from it.
    private var isReading: Bool {
        #if os(tvOS)
            focusedMessage != nil
        #else
            false
        #endif
    }
    private var visibleMessages: [LiveChatMessage] { blockStore.filterMessages(messages) }
    private var visiblePinned: LiveChatMessage? {
        pinned.flatMap { blockStore.isChatUserBlocked(id: $0.userID, name: $0.authorName) ? nil : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n(isReplay ? "live.chat.replay" : "live.chat")).fanousFont(.label).fontWeight(.bold)
                .foregroundStyle(Fanous.textPrimary)
                .padding(FanousScale.spacingMd)
                .accessibilityAddTraits(.isHeader)
            #if os(tvOS)
                if onReportMessage != nil, !visibleMessages.isEmpty || visiblePinned != nil {
                    Text(l10n("safety.report.tvChatHint")).fanousFont(.caption)
                        .foregroundStyle(Fanous.textSecondary)
                        .padding([.horizontal, .bottom], FanousScale.spacingMd)
                        .accessibilityIdentifier("tv-report-chat-hint")
                }
            #endif
            Rectangle().fill(Fanous.divider).frame(height: 1)
            if let visiblePinned {
                HStack(alignment: .top, spacing: FanousScale.spacingSm) {
                    Image(systemName: "pin").foregroundStyle(Fanous.textSecondary).accessibilityLabel(l10n("live.chat.pinned"))
                    line(visiblePinned)
                }
                .padding(FanousScale.spacingMd)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fanousMaterial(.control) { _ in .rect }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("live-chat-pinned")
            }
            if visibleMessages.isEmpty {
                Text(l10n(isReplay ? "live.chat.replayEmpty" : "live.chat.empty")).fanousFont(.body)
                    .foregroundStyle(Fanous.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal)
                    .accessibilityIdentifier("live-chat-empty")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: FanousScale.spacingMd) {
                            ForEach(visibleMessages) { line($0).id($0.id) }
                        }
                        .padding(FanousScale.spacingMd)
                    }
                    .defaultScrollAnchor(isReplay ? .top : .bottom)
                    .onChange(of: visibleMessages.last?.id) { _, last in
                        if let last, !isReading { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .frame(minHeight: 160)
            }
        }
        // Fills the room it is given, so it is the same card with and without messages
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fanousMaterial(.card) { .rounded($0.lg) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-chat")
        #if os(iOS) || os(macOS)
            .sheet(
                isPresented: Binding(
                    get: { blockingMessage != nil },
                    set: { if !$0 { blockingMessage = nil } }
                )
            ) {
                if let msg = blockingMessage {
                    ViewerBlockConfirmSheet(
                        title: l10n("safety.block.userTitle", msg.authorName),
                        message: l10n("safety.block.userMessage")
                    ) {
                        blockStore.blockChatUser(id: msg.userID, name: msg.authorName)
                    }
                }
            }
        #endif
    }

    private func line(_ message: LiveChatMessage) -> some View {
        Group {
            #if os(tvOS)
                if let onReportMessage {
                    Button {
                        onReportMessage(message)
                    } label: {
                        messageBody(message)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TVRowButtonStyle())
                    .focused($focusedMessage, equals: message.id)
                    .accessibilityHint(l10n("safety.report.message"))
                    .accessibilityIdentifier("tv-report-chat-\(message.id)")
                } else {
                    messageBody(message)
                }
            #else
                let userID = message.userID?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasUserID = userID?.isEmpty == false
                HStack(alignment: .top, spacing: FanousScale.spacingXs) {
                    messageBody(message)
                    Menu {
                        Link(
                            destination: ViewerReportURL.liveChat(
                                streamID: streamID, messageID: message.id, language: l10n.language.rawValue,
                                webBaseURL: webBaseURL)
                        ) {
                            Label(l10n("safety.report.message"), systemImage: "flag")
                        }
                        .accessibilityIdentifier("report-chat-\(message.id)")
                        if hasUserID {
                            Button {
                                blockingMessage = message
                            } label: {
                                Label(l10n("safety.block.user"), systemImage: "hand.raised.slash")
                            }
                            .accessibilityIdentifier("block-chat-user-\(message.id)")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption)
                            .foregroundStyle(Fanous.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel(l10n("safety.moreActionsFor", message.authorName))
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat-actions-\(message.id)")
                }
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-chat-message-\(message.id)")
    }

    private func messageBody(_ message: LiveChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if isReplay {
                    Text(DisplayFormat.duration(Double(message.offsetMs) / 1000, l10n.language)).monospacedDigit()
                        .foregroundStyle(Fanous.textSecondary)
                }
                Text(message.authorName).fontWeight(.semibold).foregroundStyle(Fanous.textSecondary)
                if let role = message.authorRole { LiveTag(text: l10n("live.chat.role.\(role.rawValue)")) }
            }
            .fanousFont(.caption)
            Text(message.text).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// In place of the player: what is coming, over, or cancelled.
struct LiveNotice: View {
    @Environment(\.l10n) private var l10n
    let content: LiveContent
    let untilStart: Double?

    private var isPremiere: Bool { content.timed.state.kind == .premiere }
    private var start: Date? { content.timed.state.scheduledStart ?? content.stream.scheduledStart }

    var body: some View {
        VStack(spacing: FanousScale.spacingMd) {
            switch content.mode {
            case .soon:
                countdown
                Text(l10n(isPremiere ? "live.premiere.together" : "live.soon.body")).fanousFont(.body)
                    .foregroundStyle(Fanous.textSecondary)
                if let start {
                    Text(l10n("live.scheduledFor", DisplayFormat.dateTime(start, l10n.language))).fanousFont(.body)
                        .foregroundStyle(Fanous.textSecondary)
                }
            case .cancelled: headline(l10n(isPremiere ? "live.premiere.cancelled" : "live.cancelled"))
            default:
                headline(l10n(isPremiere ? "live.premiere.ended" : "live.ended"))
                if !isPremiere { Text(l10n("live.recordingPreparing")).fanousFont(.body).foregroundStyle(Fanous.textSecondary) }
            }
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, minHeight: 200)
        .fanousMaterial(.card) { .rounded($0.lg) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-notice")
    }

    @ViewBuilder private var countdown: some View {
        if !isPremiere {
            headline(l10n("live.soon"))
        } else if let untilStart, untilStart > 0 {
            if untilStart >= 86_400 {
                let days = Int(untilStart / 86_400)
                headline(
                    l10n(
                        "live.premiere.inDays.\(DisplayFormat.pluralCategory(days, l10n.language))",
                        DisplayFormat.number(days, l10n.language)))
            } else {
                Text(l10n("live.premiere.in")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                Text(DisplayFormat.duration(untilStart.rounded(.up), l10n.language))
                    .fanousFont(.title).fontWeight(.bold).monospacedDigit()
                    .foregroundStyle(Fanous.textPrimary)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("live-countdown")
            }
        } else {
            headline(l10n("live.premiere.starting"))
        }
    }

    private func headline(_ text: String) -> some View {
        Text(text).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
    }
}

/// Title, tags, and how many are watching.
struct LiveDetails: View {
    @Environment(\.l10n) private var l10n
    @State private var confirmBlockChannel = false
    let content: LiveContent
    let viewers: Int?
    let webBaseURL: URL

    private var blockStore: ViewerBlockStore { .shared }
    private var channelName: String? { content.stream.channelName }
    private var channelID: String? {
        let trimmed = content.stream.channelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
    private var blockLabel: String? {
        if let channelName, !channelName.isEmpty { return channelName }
        return channelID != nil ? l10n("safety.blockedList.kind.channel") : nil
    }
    private var isBlocked: Bool {
        blockStore.isChannelBlocked(id: content.stream.channelID, name: channelName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if content.mode == .live || content.timed.state.kind == .premiere || content.timed.state.eventType != nil {
                LiveTags(
                    kind: content.timed.state.kind, event: content.timed.state.eventType, isLive: content.mode == .live)
            }
            HStack(alignment: .top, spacing: FanousScale.spacingSm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.stream.title).fanousFont(.title).fontWeight(.bold).foregroundStyle(Fanous.textPrimary)
                        .accessibilityIdentifier("live-title")
                    let meta = DisplayFormat.meta([content.stream.channelName, watching], l10n.language)
                    if !meta.isEmpty { Text(meta).fanousFont(.caption).foregroundStyle(Fanous.textSecondary) }
                }
                Spacer(minLength: 0)
                #if os(iOS) || os(macOS)
                    Menu {
                        Link(
                            destination: ViewerReportURL.liveStream(
                                id: content.stream.id, language: l10n.language.rawValue, webBaseURL: webBaseURL)
                        ) {
                            Label(l10n("safety.report.stream"), systemImage: "flag")
                        }
                        .accessibilityIdentifier("report-live-stream")
                        if let channelID {
                            Link(
                                destination: ViewerReportURL.channel(
                                    id: channelID, language: l10n.language.rawValue, webBaseURL: webBaseURL)
                            ) {
                                Label(l10n("safety.report.channel"), systemImage: "flag")
                            }
                            .accessibilityIdentifier("report-live-channel")
                        }
                        if blockLabel != nil, !isBlocked {
                            Button {
                                confirmBlockChannel = true
                            } label: {
                                Label(l10n("safety.block.channel"), systemImage: "hand.raised.slash")
                            }
                            .accessibilityIdentifier("block-live-channel")
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
                    .accessibilityIdentifier("live-actions-menu")
                #endif
            }
            if let description = content.stream.description, !description.isEmpty {
                Text(description).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS) || os(macOS)
            .sheet(isPresented: $confirmBlockChannel) {
                if let label = blockLabel {
                    ViewerBlockConfirmSheet(
                        title: l10n("safety.block.channelTitle", label),
                        message: l10n("safety.block.channelMessage")
                    ) {
                        blockStore.blockChannel(id: content.stream.channelID, name: channelName ?? "")
                    }
                }
            }
        #endif
    }

    private var watching: String? {
        content.mode == .live ? viewers.map { l10n("live.watching", DisplayFormat.number($0, l10n.language)) } : nil
    }
}

extension LiveContent {
    var hasChat: Bool {
        switch mode {
        case .live, .soon: timed.state.chat.enabled
        case .recording: timed.state.chat.replay
        case .ended, .cancelled: false
        }
    }
}

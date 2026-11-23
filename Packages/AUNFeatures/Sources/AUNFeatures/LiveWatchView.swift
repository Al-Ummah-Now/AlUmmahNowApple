import AUNCoreBridge
import AUNDesign
import AUNPlayer
import Foundation
import Observation
import SwiftUI

public enum LiveWatchMode: String, Equatable, Sendable {
    case live, recording, soon, ended, cancelled
}

public struct LiveWatchContent: Sendable {
    public var stream: LiveStream
    public var state: LiveStreamState
    public var mode: LiveWatchMode

    public init(stream: LiveStream, state: LiveStreamState, mode: LiveWatchMode) {
        self.stream = stream
        self.state = state
        self.mode = mode
    }
}

@MainActor @Observable
public final class LiveWatchViewModel {
    public private(set) var state: LoadState<LiveWatchContent> = .loading
    public private(set) var messages: [LiveChatMessage] = []
    public private(set) var pinnedMessage: LiveChatMessage?
    public private(set) var chatSettings = LiveChatSettings()
    public private(set) var canModerate = false
    public private(set) var reminder = LiveReminderStatus()
    public private(set) var viewers: Int?
    public private(set) var chatError: String?
    public var draft = ""
    public let player: PlayerController

    private let streamID: String
    private let catalog: any CatalogServicing
    private let viewerID = "v_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)

    public init(streamID: String, catalog: any CatalogServicing) {
        self.streamID = streamID
        self.catalog = catalog
        player = PlayerController { url in try await catalog.subtitleText(url: url) }
    }

    public static func resolveMode(_ state: LiveStreamState) -> LiveWatchMode {
        if state.status == .cancelled { return .cancelled }
        if state.status == .ended || state.sessionStatus == "ended" {
            return state.vodURL != nil ? .recording : .ended
        }
        if (state.status == .live || state.sessionStatus == "live") && state.playbackURL != nil {
            return .live
        }
        return .soon
    }

    public func load(language: AppLanguage, autoplay: Bool = true) async {
        state = .loading
        do {
            async let loadedStream = catalog.liveStream(id: streamID)
            async let loadedState = catalog.liveStreamState(id: streamID)
            let (stream, liveState) = try await (loadedStream, loadedState)
            let mode = Self.resolveMode(liveState)
            viewers = liveState.viewers ?? stream.currentViewers
            chatSettings = liveState.chat
            pinnedMessage = liveState.chat.pinnedMessage
            reminder = liveState.reminders
            state = .loaded(LiveWatchContent(stream: stream, state: liveState, mode: mode))

            if mode == .live, let url = liveState.playbackURL ?? stream.playbackURL {
                player.load(
                    PlaybackItem(
                        url: url, title: stream.title, subtitle: stream.channelName,
                        isLiveStream: liveState.kind == .live,
                        dvrWindowSeconds: Double(liveState.dvrWindowSeconds)),
                    autoplay: autoplay)
                if let count = try? await catalog.beatLiveViewer(streamID: streamID, viewerID: String(viewerID), leaving: false) {
                    viewers = count
                }
            } else if mode == .recording, let url = liveState.vodURL ?? stream.vodURL {
                player.load(
                    PlaybackItem(url: url, title: stream.title, subtitle: stream.channelName),
                    autoplay: autoplay)
            }

            if (mode == .live || mode == .soon) && liveState.chat.enabled {
                await refreshChat()
            } else if mode == .recording && liveState.chat.replayEnabled {
                await refreshChat(replayOffsetMs: Int(player.currentTime * 1000))
            }
        } catch is CancellationError {
            return
        } catch {
            AUNLog.network.error("LiveWatch load failed: \(error)")
            state = .failed
        }
    }

    public func refreshChat(replayOffsetMs: Int? = nil) async {
        do {
            let page = try await catalog.liveChatMessages(
                streamID: streamID, afterID: nil,
                afterOffsetMs: replayOffsetMs != nil ? 0 : nil,
                toOffsetMs: replayOffsetMs.map { max(5_000, $0 + 2_000) },
                limit: 50)
            messages = page.messages
            pinnedMessage = page.pinnedMessage
            chatSettings = page.settings
            canModerate = page.canModerate
        } catch {
            AUNLog.network.error("Live chat refresh failed: \(error)")
        }
    }

    public func sendChat() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rejected = LiveChatFastFilter.check(trimmed, canPostLinks: canModerate) {
            chatError = rejected.rawValue
            return
        }
        chatError = nil
        do {
            let msg = try await catalog.postLiveChatMessage(streamID: streamID, text: trimmed)
            draft = ""
            if !messages.contains(where: { $0.id == msg.id }) {
                messages.append(msg)
            }
        } catch {
            chatError = "send_failed"
        }
    }

    public func moderate(_ message: LiveChatMessage, action: LiveModerationAction) async {
        do {
            try await catalog.moderateLiveChatMessage(streamID: streamID, messageID: message.id, action: action)
            switch action {
            case .remove, .blockAuthor:
                messages.removeAll { $0.id == message.id }
                if pinnedMessage?.id == message.id { pinnedMessage = nil }
            case .pin:
                var pinned = message
                pinned.isPinned = true
                pinnedMessage = pinned
            case .unpin:
                pinnedMessage = nil
            case .approve:
                break
            }
        } catch {
            AUNLog.network.error("Live chat moderation failed: \(error)")
        }
    }

    public func report(_ message: LiveChatMessage, reason: LiveReportReason) async {
        do {
            try await catalog.reportLiveChatMessage(messageID: message.id, reason: reason, description: nil)
        } catch {
            AUNLog.network.error("Live chat report failed: \(error)")
        }
    }

    public func toggleReminder() async {
        let next = !reminder.viewerSubscribed
        do {
            reminder = try await catalog.setLiveReminder(streamID: streamID, subscribed: next)
        } catch {
            AUNLog.network.error("Live reminder toggle failed: \(error)")
        }
    }

    public func stop() {
        player.stop()
        let id = streamID
        let viewer = String(viewerID)
        let cat = catalog
        Task {
            _ = try? await cat.beatLiveViewer(streamID: id, viewerID: viewer, leaving: true)
        }
    }
}

#if os(iOS) || os(macOS) || os(tvOS)
    public struct LiveWatchView: View {
        @Environment(\.l10n) private var l10n
        @State private var model: LiveWatchViewModel

        public init(streamID: String, catalog: any CatalogServicing) {
            _model = State(initialValue: LiveWatchViewModel(streamID: streamID, catalog: catalog))
        }

        public var body: some View {
            Group {
                switch model.state {
                case .loading:
                    ThemeLoader()
                case .failed:
                    ErrorStateView { Task { await model.load(language: l10n.language) } }
                case .loaded(let content):
                    loadedView(content)
                }
            }
            .fanousPage()
            .task { await model.load(language: l10n.language) }
            .onDisappear { model.stop() }
        }

        @ViewBuilder
        private func loadedView(_ content: LiveWatchContent) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                    playerSection(content)
                    headerSection(content)
                    if showChat(content) {
                        chatSection(content)
                    }
                }
                .padding()
            }
        }

        @ViewBuilder
        private func playerSection(_ content: LiveWatchContent) -> some View {
            if content.mode == .live || content.mode == .recording {
                ZStack(alignment: .bottomTrailing) {
                    PlayerSurface(controller: model.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .accessibilityIdentifier("live-player")
                    if content.mode == .live && !model.player.isAtLiveEdge {
                        Button(l10n("live.returnToLive")) {
                            model.player.seekToLiveEdge()
                        }
                        .buttonStyle(FanousButtonStyle(.primary))
                        .padding(FanousScale.spacingMd)
                        .accessibilityIdentifier("live-return-to-live")
                    }
                }
            } else {
                VStack(spacing: FanousScale.spacingMd) {
                    Text(l10n(statusKey(content.mode)))
                        .fanousFont(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(Fanous.textPrimary)
                    if content.mode == .soon {
                        Text(l10n("live.startingSoonBody"))
                            .fanousFont(.body)
                            .foregroundStyle(Fanous.textSecondary)
                            .multilineTextAlignment(.center)
                        if model.reminder.enabled {
                            Button(l10n(model.reminder.viewerSubscribed ? "live.notifyingYou" : "live.notifyMe")) {
                                Task { await model.toggleReminder() }
                            }
                            .buttonStyle(FanousButtonStyle(.primary))
                            .accessibilityIdentifier("live-reminder-toggle")
                        }
                    }
                }
                .padding(FanousScale.spacingLg)
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .fanousMaterial(.card) { .rounded($0.lg) }
                .accessibilityIdentifier("live-notice")
            }
        }

        private func headerSection(_ content: LiveWatchContent) -> some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                HStack(spacing: FanousScale.spacingSm) {
                    Text(l10n(badgeKey(content.mode)))
                        .fanousFont(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Fanous.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .fanousMaterial(.control) { .rounded($0.sm) }
                        .accessibilityIdentifier("live-status-badge")
                    if content.state.kind == .premiere {
                        Text(l10n("live.premiere"))
                            .fanousFont(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Fanous.link)
                            .accessibilityIdentifier("live-premiere-badge")
                    }
                    if let event = content.state.eventType {
                        Text(l10n("live.event.\(event.rawValue)"))
                            .fanousFont(.caption)
                            .foregroundStyle(Fanous.textSecondary)
                            .accessibilityIdentifier("live-event-badge")
                    }
                }
                Text(content.stream.title)
                    .fanousFont(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(Fanous.textPrimary)
                    .accessibilityIdentifier("live-watch-title")
                if let count = model.viewers, content.mode == .live {
                    Text(l10n("live.watching", DisplayFormat.number(count, l10n.language)))
                        .fanousFont(.caption)
                        .foregroundStyle(Fanous.textSecondary)
                        .accessibilityIdentifier("live-watch-viewers")
                }
            }
        }

        @ViewBuilder
        private func chatSection(_ content: LiveWatchContent) -> some View {
            let isReplay = content.mode == .recording
            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                HStack {
                    Text(l10n(isReplay ? "live.chat.replayTitle" : "live.chat.title"))
                        .fanousFont(.label)
                        .fontWeight(.bold)
                        .foregroundStyle(Fanous.textPrimary)
                    Spacer()
                    if !isReplay && model.chatSettings.slowModeSeconds > 0 {
                        Text(l10n("live.chat.slowMode", DisplayFormat.number(model.chatSettings.slowModeSeconds, l10n.language)))
                            .fanousFont(.caption)
                            .foregroundStyle(Fanous.textSecondary)
                    }
                }
                if let pinned = model.pinnedMessage {
                    HStack {
                        Text("\(l10n("live.chat.pinned")): \(pinned.authorName) — \(pinned.text)")
                            .fanousFont(.caption)
                            .foregroundStyle(Fanous.textPrimary)
                        Spacer()
                    }
                    .padding(FanousScale.spacingSm)
                    .fanousMaterial(.control) { .rounded($0.sm) }
                    .accessibilityIdentifier("live-chat-pinned")
                }
                if model.messages.isEmpty {
                    Text(l10n("live.chat.empty"))
                        .fanousFont(.caption)
                        .foregroundStyle(Fanous.textSecondary)
                        .accessibilityIdentifier("live-chat-empty")
                } else {
                    ForEach(model.messages) { message in
                        HStack(alignment: .top, spacing: FanousScale.spacingSm) {
                            Text(DisplayFormat.duration(Double(max(0, message.offsetMs)) / 1000, l10n.language))
                                .fanousFont(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Fanous.textSecondary)
                            Text(message.authorName)
                                .fanousFont(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(Fanous.textPrimary)
                            Text(message.text)
                                .fanousFont(.caption)
                                .foregroundStyle(Fanous.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .accessibilityIdentifier("live-chat-message-\(message.id)")
                    }
                }
                #if !os(tvOS)
                    if !isReplay {
                        HStack(spacing: FanousScale.spacingSm) {
                            TextField(l10n("live.chat.placeholder"), text: $model.draft)
                                .accessibilityIdentifier("live-chat-input")
                            Button(l10n("live.chat.send")) {
                                Task { await model.sendChat() }
                            }
                            .buttonStyle(FanousButtonStyle(.primary))
                            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("live-chat-send")
                        }
                    }
                #endif
            }
            .padding(FanousScale.spacingLg)
            .fanousMaterial(.card) { .rounded($0.lg) }
            .accessibilityIdentifier("live-chat-panel")
        }

        private func showChat(_ content: LiveWatchContent) -> Bool {
            if content.mode == .recording { return model.chatSettings.replayEnabled }
            return (content.mode == .live || content.mode == .soon) && model.chatSettings.enabled
        }

        private func statusKey(_ mode: LiveWatchMode) -> String {
            switch mode {
            case .soon: "live.startingSoon"
            case .ended: "live.ended"
            case .cancelled: "live.cancelled"
            case .live: "live.badge"
            case .recording: "live.recording"
            }
        }

        private func badgeKey(_ mode: LiveWatchMode) -> String {
            switch mode {
            case .live: "live.badge"
            case .recording: "live.recording"
            case .soon: "live.startingSoon"
            case .ended: "live.ended"
            case .cancelled: "live.cancelled"
            }
        }
    }
#endif

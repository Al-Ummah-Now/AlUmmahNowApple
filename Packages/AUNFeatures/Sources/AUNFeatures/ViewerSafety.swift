import AUNCoreBridge
import AUNDesign
import Foundation
import SwiftUI

/// Web URLs for reporting videos, channels, live streams, and live chat messages from guest viewers
/// (App Store 1.2, AlUmmahNowApple#91).
public enum ViewerReportURL {
    private static func localeSegment(_ language: String) -> String {
        language.lowercased().hasPrefix("ar") ? "ar" : "en"
    }

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    public static func video(id: String, language: String) -> URL {
        URL(string: "https://videos.alummahnow.net/\(localeSegment(language))/video/\(encoded(id))?report=video")!
    }

    public static func channel(id: String?, name: String?, language: String) -> URL {
        let target = id ?? name ?? ""
        return URL(
            string:
                "https://videos.alummahnow.net/\(localeSegment(language))/contact?from=app-report&type=channel&id=\(encoded(target))"
        )!
    }

    public static func liveStream(id: String, language: String) -> URL {
        URL(string: "https://videos.alummahnow.net/\(localeSegment(language))/live/\(encoded(id))?report=livestream")!
    }

    public static func liveChat(streamID: String, messageID: String, language: String) -> URL {
        URL(
            string:
                "https://videos.alummahnow.net/\(localeSegment(language))/contact?from=app-report&type=live_chat&stream=\(encoded(streamID))&message=\(encoded(messageID))"
        )!
    }
}

/// One blocked channel or live-chat author stored on this device while the viewer is guest-only.
public struct BlockedEntry: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case channel, chatUser }

    public var id: String
    public var kind: Kind
    public var name: String
    public var blockedAt: Date

    public init(id: String, kind: Kind, name: String, blockedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.blockedAt = blockedAt
    }
}

/// Device-local block list for the guest Viewer apps (App Store 1.2, AlUmmahNowApple#91).
/// Hides videos and live streams from blocked channels and messages from blocked live-chat users immediately.
@MainActor @Observable
public final class ViewerBlockStore {
    public static let shared = ViewerBlockStore()

    public private(set) var entries: [BlockedEntry] = []

    private let defaults: UserDefaults
    private let key = "AUNViewerBlockedEntries"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([BlockedEntry].self, from: data) {
            entries = decoded
        }
    }

    public func blockChannel(id: String?, name: String) {
        let keyID = Self.channelKey(id: id, name: name)
        guard !entries.contains(where: { $0.id == keyID }) else { return }
        entries.insert(BlockedEntry(id: keyID, kind: .channel, name: name), at: 0)
        save()
    }

    public func blockChatUser(name: String) {
        let keyID = Self.chatUserKey(name: name)
        guard !entries.contains(where: { $0.id == keyID }) else { return }
        entries.insert(BlockedEntry(id: keyID, kind: .chatUser, name: name), at: 0)
        save()
    }

    public func unblock(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func isChannelBlocked(id: String?, name: String?) -> Bool {
        let byID = id.map { Self.channelKey(id: $0, name: name ?? "") }
        let byName = name.map { Self.channelKey(id: nil, name: $0) }
        return entries.contains { entry in
            entry.kind == .channel
                && (entry.id == byID || entry.id == byName
                    || (name != nil && entry.name.caseInsensitiveCompare(name!) == .orderedSame))
        }
    }

    public func isChatUserBlocked(name: String) -> Bool {
        let keyID = Self.chatUserKey(name: name)
        return entries.contains { $0.kind == .chatUser && $0.id == keyID }
    }

    public func filterVideos(_ videos: [Video]) -> [Video] {
        videos.filter { !isChannelBlocked(id: $0.channelID, name: $0.channelName) }
    }

    public func filterRails(_ rails: [HomeRail]) -> [HomeRail] {
        rails.compactMap { rail in
            let kept = filterVideos(rail.videos)
            return kept.isEmpty ? nil : HomeRail(kind: rail.kind, videos: kept)
        }
    }

    public func filterLiveStreams(_ streams: [LiveStream]) -> [LiveStream] {
        streams.filter { !isChannelBlocked(id: nil, name: $0.channelName) }
    }

    public func filterMessages(_ messages: [LiveChatMessage]) -> [LiveChatMessage] {
        messages.filter { !isChatUserBlocked(name: $0.authorName) }
    }

    static func channelKey(id: String?, name: String) -> String {
        if let id, !id.isEmpty { return "channel:id:\(id)" }
        return "channel:name:\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    static func chatUserKey(name: String) -> String {
        "user:\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Accessible in-app confirmation for blocking a channel or chat user (never a system alert).
struct ViewerBlockConfirmSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @FocusState private var cancelFocused: Bool
    @AccessibilityFocusState private var cancelSpoken: Bool

    let title: String
    let message: String
    let onConfirm: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: FanousScale.spacingLg) {
                Image(systemName: "hand.raised.slash")
                    .font(.title)
                    .foregroundStyle(Fanous.errorText)
                    .accessibilityHidden(true)
                Text(title)
                    .fanousFont(.title)
                    .foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .fanousFont(.body)
                    .foregroundStyle(Fanous.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits {
                    HStack(spacing: FanousScale.spacingMd) { buttons }
                    VStack(spacing: FanousScale.spacingMd) { buttons }
                }
            }
            .multilineTextAlignment(.center)
            .padding(FanousScale.spacingXl)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            cancelFocused = true
            cancelSpoken = true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fanousPage()
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationBackground { FanousSurfaceKind(kind: .page, shape: .rect) }
        #elseif os(macOS)
            .frame(minWidth: 400, minHeight: 280)
        #endif
    }

    @ViewBuilder private var buttons: some View {
        Button(l10n("common.cancel")) { dismiss() }
            .buttonStyle(FanousButtonStyle(.primary))
            .keyboardShortcut(.cancelAction)
            .focused($cancelFocused)
            .accessibilityFocused($cancelSpoken)
            .accessibilityIdentifier("block-confirm-cancel")
        Button(role: .destructive) {
            onConfirm()
            dismiss()
        } label: {
            Text(l10n("safety.block.confirm")).foregroundStyle(Fanous.errorText)
        }
        .buttonStyle(FanousButtonStyle(.secondary))
        .accessibilityIdentifier("block-confirm-action")
    }
}

#if os(iOS) || os(macOS)
    /// Manage channels and live-chat users blocked on this device.
    struct BlockedListSheet: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.dismiss) private var dismiss
        let store: ViewerBlockStore

        var body: some View {
            NavigationStack {
                Group {
                    if store.entries.isEmpty {
                        EmptyStateView(
                            title: l10n("safety.blockedList.emptyTitle"),
                            message: l10n("safety.blockedList.emptyMessage")
                        )
                        .accessibilityIdentifier("blocked-list-empty")
                    } else {
                        List {
                            ForEach(store.entries) { entry in
                                HStack(spacing: FanousScale.spacingMd) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .fanousFont(.body)
                                            .foregroundStyle(Fanous.textPrimary)
                                        Text(
                                            l10n(
                                                entry.kind == .channel
                                                    ? "safety.blockedList.kind.channel" : "safety.blockedList.kind.user"
                                            )
                                        )
                                        .fanousFont(.caption)
                                        .foregroundStyle(Fanous.textSecondary)
                                    }
                                    Spacer(minLength: 0)
                                    Button(l10n("safety.unblock")) { store.unblock(id: entry.id) }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(Fanous.accent)
                                        .accessibilityIdentifier("unblock-\(entry.id)")
                                }
                                .listRowBackground(Rectangle().fill(Fanous.surfaceRaised))
                            }
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
                .fanousPage()
                .navigationTitle(l10n("safety.blockedList.title"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(l10n("common.dismiss")) { dismiss() }
                            .accessibilityIdentifier("blocked-list-done")
                    }
                }
            }
            #if os(macOS)
                .frame(minWidth: 420, minHeight: 360)
            #endif
        }
    }
#endif

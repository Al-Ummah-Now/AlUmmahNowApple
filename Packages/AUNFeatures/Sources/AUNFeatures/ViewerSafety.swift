import AUNCoreBridge
import AUNDesign
import Foundation
import SwiftUI

/// Web URLs for reporting videos, channels, live streams, and live chat messages from guest viewers
/// (App Store 1.2, AlUmmahNowApple#91). Points at the public guest `/[locale]/report` page.
public enum ViewerReportURL {
    private static func localeSegment(_ language: String) -> String {
        language.lowercased().hasPrefix("ar") ? "ar" : "en"
    }

    private static func build(webBaseURL: URL, language: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: webBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        if components.scheme == nil { components.scheme = "https" }
        if components.host == nil {
            components.host = AppEnvironment.qa.webBaseURL.host
        }
        components.path = "/\(localeSegment(language))/report"
        components.queryItems = queryItems.filter { !($0.value ?? "").isEmpty }
        components.fragment = nil
        return components.url ?? webBaseURL
    }

    public static func video(id: String, language: String, webBaseURL: URL) -> URL {
        build(
            webBaseURL: webBaseURL, language: language,
            queryItems: [URLQueryItem(name: "type", value: "video"), URLQueryItem(name: "id", value: id)]
        )
    }

    public static func channel(id: String, language: String, webBaseURL: URL) -> URL {
        build(
            webBaseURL: webBaseURL, language: language,
            queryItems: [URLQueryItem(name: "type", value: "channel"), URLQueryItem(name: "id", value: id)]
        )
    }

    public static func liveStream(id: String, language: String, webBaseURL: URL) -> URL {
        build(
            webBaseURL: webBaseURL, language: language,
            queryItems: [URLQueryItem(name: "type", value: "livestream"), URLQueryItem(name: "id", value: id)]
        )
    }

    public static func liveChat(
        streamID: String, messageID: String, language: String, webBaseURL: URL
    ) -> URL {
        build(
            webBaseURL: webBaseURL, language: language,
            queryItems: [
                URLQueryItem(name: "type", value: "live_chat"),
                URLQueryItem(name: "stream", value: streamID),
                URLQueryItem(name: "message", value: messageID),
            ]
        )
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

    public func blockChatUser(id: String? = nil, name: String) {
        let keyID = Self.chatUserKey(id: id, name: name)
        guard !entries.contains(where: { $0.id == keyID }) else { return }
        entries.insert(BlockedEntry(id: keyID, kind: .chatUser, name: name), at: 0)
        save()
    }

    public func unblock(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Removes any blocked channel entry matching `id` or fallback `name` (handles entries saved before a channel ID was present).
    public func unblockChannel(id: String?, name: String?) {
        let cleanID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let byID = (cleanID?.isEmpty == false) ? Self.channelKey(id: cleanID, name: name ?? "") : nil
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let byName = (cleanName?.isEmpty == false) ? Self.channelKey(id: nil, name: cleanName!) : nil
        entries.removeAll { entry in
            guard entry.kind == .channel else { return false }
            if let byID, entry.id == byID { return true }
            if byID != nil && entry.id.hasPrefix("channel:id:") { return false }
            if let byName, entry.id == byName { return true }
            if let cleanName, !cleanName.isEmpty, entry.name.caseInsensitiveCompare(cleanName) == .orderedSame {
                return true
            }
            return false
        }
        save()
    }

    public func isChannelBlocked(id: String?, name: String?) -> Bool {
        let cleanID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let byID = (cleanID?.isEmpty == false) ? Self.channelKey(id: cleanID, name: name ?? "") : nil
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let byName = (cleanName?.isEmpty == false) ? Self.channelKey(id: nil, name: cleanName!) : nil
        return entries.contains { entry in
            guard entry.kind == .channel else { return false }
            if let byID, entry.id == byID { return true }
            // When both the stored block and the queried channel carry a stable ID, match by ID only so
            // two distinct channels that happen to share a display name never collide.
            if byID != nil && entry.id.hasPrefix("channel:id:") { return false }
            if let byName, entry.id == byName { return true }
            if let cleanName, !cleanName.isEmpty, entry.name.caseInsensitiveCompare(cleanName) == .orderedSame {
                return true
            }
            return false
        }
    }

    public func isChatUserBlocked(id: String? = nil, name: String?) -> Bool {
        let cleanID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let byID = (cleanID?.isEmpty == false) ? Self.chatUserKey(id: cleanID, name: name ?? "") : nil
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let byName = (cleanName?.isEmpty == false) ? Self.chatUserKey(id: nil, name: cleanName!) : nil
        let legacyName = (cleanName?.isEmpty == false) ? "user:\(cleanName!.lowercased())" : nil
        return entries.contains { entry in
            guard entry.kind == .chatUser else { return false }
            if let byID, entry.id == byID { return true }
            if byID != nil && entry.id.hasPrefix("user:id:") { return false }
            if let byName, entry.id == byName { return true }
            if let legacyName, entry.id == legacyName { return true }
            return false
        }
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
        streams.filter { !isChannelBlocked(id: $0.channelID, name: $0.channelName) }
    }

    public func filterMessages(_ messages: [LiveChatMessage]) -> [LiveChatMessage] {
        messages.filter { !isChatUserBlocked(id: $0.userID, name: $0.authorName) }
    }

    static func channelKey(id: String?, name: String) -> String {
        if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return "channel:id:\(id)" }
        return "channel:name:\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    static func chatUserKey(id: String? = nil, name: String) -> String {
        if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return "user:id:\(id)" }
        return "user:name:\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var cancelFocused: Bool
    @AccessibilityFocusState private var cancelSpoken: Bool
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 15

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
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.system(size: bodySize))
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
        .environment(\.layoutDirection, l10n.language.isRTL ? .rightToLeft : .leftToRight)
        #if os(iOS)
            .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            .presentationBackground { FanousSurfaceKind(kind: .page, shape: .rect) }
        #elseif os(macOS)
            .frame(minWidth: 400, minHeight: 280)
        #endif
    }

    @ViewBuilder private var buttons: some View {
        let cancel = Button {
            dismiss()
        } label: {
            Text(l10n("common.cancel"))
                .font(.system(size: labelSize, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(FanousButtonStyle(.primary))
        .focused($cancelFocused)
        .accessibilityFocused($cancelSpoken)
        .accessibilityIdentifier("block-confirm-cancel")
        #if !os(tvOS)
            cancel.keyboardShortcut(.cancelAction)
        #else
            cancel
        #endif
        Button(role: .destructive) {
            onConfirm()
            dismiss()
        } label: {
            Text(l10n("safety.block.confirm"))
                .font(.system(size: labelSize, weight: .semibold))
                .foregroundStyle(Fanous.errorText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(FanousButtonStyle(.secondary))
        .accessibilityIdentifier("block-confirm-action")
    }
}

/// Full-width blocked-channel placeholder with wrapped message and Unblock action (scales with Dynamic Type).
struct BlockedChannelCard: View {
    @Environment(\.l10n) private var l10n
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 15

    let channelDisplayName: String
    let cardIdentifier: String
    let unblockIdentifier: String
    let onUnblock: () -> Void

    var body: some View {
        VStack(spacing: FanousScale.spacingMd) {
            Image(systemName: "hand.raised.slash")
                .font(.title2)
                .foregroundStyle(Fanous.textSecondary)
                .accessibilityHidden(true)
            Text(l10n("safety.blocked.channelBanner", channelDisplayName))
                .font(.system(size: bodySize))
                .foregroundStyle(Fanous.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onUnblock()
            } label: {
                Text(l10n("safety.unblock"))
                    .font(.system(size: labelSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(FanousButtonStyle(.secondary))
            .accessibilityIdentifier(unblockIdentifier)
        }
        .padding(FanousScale.spacingXl)
        .frame(maxWidth: 640, minHeight: 220)
        .frame(maxWidth: .infinity)
        .fanousMaterial(.hero) { .rounded($0.lg) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(cardIdentifier)
    }
}

#if os(iOS) || os(macOS)
    /// Manage channels and live-chat users blocked on this device.
    struct BlockedListSheet: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.dismiss) private var dismiss
        @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 16
        @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 13
        @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 15
        let store: ViewerBlockStore

        var body: some View {
            NavigationStack {
                Group {
                    if store.entries.isEmpty {
                        EmptyStateView(
                            title: l10n("safety.blockedList.emptyTitle"),
                            message: l10n("safety.blockedList.emptyMessage")
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("blocked-list-empty")
                    } else {
                        List {
                            ForEach(store.entries) { entry in
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: FanousScale.spacingMd) {
                                        entryLabels(entry)
                                        Spacer(minLength: 0)
                                        unblockButton(entry)
                                    }
                                    VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                                        entryLabels(entry)
                                        unblockButton(entry)
                                    }
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(Rectangle().fill(Fanous.surfaceRaised))
                            }
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
                .fanousPage()
                .navigationTitle(l10n("safety.blockedList.title"))
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    #if os(iOS)
                        ToolbarItem(placement: .principal) {
                            Text(l10n("safety.blockedList.title"))
                                .fanousFont(.headline)
                                .foregroundStyle(Fanous.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    #endif
                    ToolbarItem(placement: .cancellationAction) {
                        Button(l10n("common.dismiss")) { dismiss() }
                            .foregroundStyle(Fanous.textPrimary)
                            .accessibilityIdentifier("blocked-list-done")
                    }
                }
            }
            .environment(\.layoutDirection, l10n.language.isRTL ? .rightToLeft : .leftToRight)
            #if os(macOS)
                .frame(minWidth: 420, minHeight: 360)
            #endif
        }

        private func entryLabels(_ entry: BlockedEntry) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: bodySize, weight: .medium))
                    .foregroundStyle(Fanous.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    l10n(
                        entry.kind == .channel
                            ? "safety.blockedList.kind.channel" : "safety.blockedList.kind.user"
                    )
                )
                .font(.system(size: captionSize))
                .foregroundStyle(Fanous.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func unblockButton(_ entry: BlockedEntry) -> some View {
            Button {
                store.unblock(id: entry.id)
            } label: {
                Text(l10n("safety.unblock"))
                    .font(.system(size: labelSize, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Fanous.accent)
            .frame(minHeight: 44)
            .accessibilityLabel(l10n("safety.unblockFor", entry.name))
            .accessibilityIdentifier("unblock-\(entry.id)")
        }
    }
#endif

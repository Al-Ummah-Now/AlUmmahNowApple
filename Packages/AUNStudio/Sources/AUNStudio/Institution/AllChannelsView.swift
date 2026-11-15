import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Every channel the account owns or helps run (`GET /api/channels/access`), with each one's last 28 days, and a switch
/// to work in it.
struct AllChannelsView: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession
    @State private var stats: [String: ChannelStats] = [:]
    @State private var unavailable: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
                Text(l10n("studio.channels.hint")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                if session.allChannels.isEmpty {
                    EmptyStateView(title: l10n("studio.channel.none"), message: l10n("studio.channel.noneMessage"))
                }
                ForEach(session.allChannels) { channel in row(channel) }
            }
            .padding(FanousScale.spacingLg)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fanousPage()
        .navigationTitle(l10n("studio.channels.title"))
        .task(id: session.allChannels.map(\.id)) { await loadStats() }
    }

    private func row(_ channel: StudioChannel) -> some View {
        let current = channel.id == session.channel?.id
        let language = l10n.language
        return HStack(spacing: FanousScale.spacingMd) {
            AvatarView(name: channel.displayName(language), url: channel.avatarURL, size: 44)
            VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                HStack(spacing: FanousScale.spacingSm) {
                    Text(channel.displayName(language)).fanousFont(.label).foregroundStyle(Fanous.textPrimary).lineLimit(1)
                    StatusChip(text: l10n("studio.role.\(channel.role.rawValue)"), emphasised: channel.role == .owner)
                    if channel.isSuspended { StatusChip(text: l10n("studio.channels.suspended"), emphasised: false) }
                }
                if let handle = channel.handle {
                    Text("@\(handle)").fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                statsLine(channel)
            }
            Spacer(minLength: FanousScale.spacingMd)
            if current {
                Label(l10n("studio.channels.current"), systemImage: "checkmark.circle.fill")
                    .fanousFont(.label).foregroundStyle(Fanous.successText)
                    .accessibilityIdentifier("channels-current-\(channel.id)")
            } else {
                Button(l10n("studio.channels.switch")) { Task { await session.select(channel) } }
                    .buttonStyle(FanousButtonStyle(.secondary))
                    .disabled(!channel.canUpload)
                    .accessibilityLabel(l10n("studio.channels.switchNamed", channel.displayName(language)))
                    .accessibilityIdentifier("channels-switch-\(channel.id)")
            }
        }
        .padding(FanousScale.spacingMd)
        .fanousMaterial(.card) { .rounded($0.md) }
        .overlay {
            if current { RoundedRectangle(cornerRadius: 12).strokeBorder(Fanous.accent, lineWidth: 1.5) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channels-row-\(channel.id)")
    }

    @ViewBuilder private func statsLine(_ channel: StudioChannel) -> some View {
        let language = l10n.language
        if let stats = stats[channel.id] {
            Text(
                l10n(
                    "studio.channels.stats", DisplayFormat.count(stats.periodViews, language),
                    DisplayFormat.count(stats.totalSubscribers, language),
                    DisplayFormat.count(stats.totalVideos, language))
            )
            .fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
        } else if !unavailable.contains(channel.id) {
            Text(l10n("common.loading")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
        }
    }

    /// The last 28 days of each channel, a few at a time; a channel whose numbers the role cannot read shows none.
    private func loadStats() async {
        let period = AnalyticsRange.days28.periods().current
        let studio = session.services.studio
        await withTaskGroup(of: (String, ChannelStats?).self) { group in
            for channel in session.allChannels {
                group.addTask {
                    (
                        channel.id,
                        try? await retryingRebuild { try await studio.channelStats(channelID: channel.id, period: period) }
                    )
                }
            }
            for await (id, result) in group {
                if let result { stats[id] = result } else { unavailable.insert(id) }
            }
        }
    }
}

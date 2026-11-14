import AUNCoreBridge
import AUNDesign
import SwiftUI

/// The queue column: tabs, live search, the offline line and the rows. Text only: no thumbnails, so nothing
/// sensitive shows before an item is opened and the list still works offline.
struct QueueColumn: View {
    @Environment(\.l10n) private var l10n
    @Bindable var model: QueueModel
    @Binding var selection: String?
    let session: AdminSession
    @State private var searchText = ""
    @State private var shownAfter: Double?

    var body: some View {
        List(selection: $selection) {
            Section {
                Picker(l10n("admin.queue.tabs"), selection: $model.tab) {
                    Text(l10n("admin.queue.actionNeeded")).tag(ReviewTab.actionNeeded)
                    Text(l10n("admin.queue.history")).tag(ReviewTab.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("queue-tabs")
                if model.isOffline || session.isOffline { OfflineLine(lastUpdated: model.lastUpdated) }
            }
            Section {
                if model.items.isEmpty {
                    emptyState
                } else {
                    ForEach(model.items) { item in
                        QueueRow(item: item, tab: model.tab, me: session.profile?.userID)
                            .tag(item.id)
                            .onAppear { if shownAfter == nil { shownAfter = LaunchClock.queueShown() } }
                            .swipeActions(edge: .trailing) {
                                if model.tab == .actionNeeded {
                                    Button(l10n("admin.queue.claim")) { claim(item) }.tint(Fanous.accent)
                                }
                            }
                            .contextMenu {
                                Button(l10n("admin.queue.open")) { selection = item.id }
                                if model.tab == .actionNeeded {
                                    Button(l10n("admin.queue.claim")) { claim(item) }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(l10n("admin.name"))
        .searchable(text: $searchText, prompt: Text(l10n("admin.queue.search")))
        .searchSuggestions {
            ForEach(model.suggestions(for: searchText), id: \.self) { suggestion in
                Text(suggestion).searchCompletion(suggestion)
            }
        }
        .onChange(of: searchText) { _, text in model.search(text) }
        .refreshable { await model.load() }
        .task { await model.load() }
        .overlay(alignment: .bottom) {
            if LaunchClock.reports, let shownAfter {
                Text(verbatim: "\(Int(shownAfter * 1000))").font(.caption2).opacity(0.02)
                    .accessibilityIdentifier("queue-shown-ms")
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity)
        } else if model.failed {
            VStack(spacing: FanousScale.spacingSm) {
                Text(l10n("admin.queue.failed")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                Button(l10n("common.retry")) { Task { await model.load() } }.buttonStyle(FanousButtonStyle(.secondary))
            }
            .frame(maxWidth: .infinity)
        } else {
            Text(l10n(model.query.isEmpty ? "admin.queue.empty" : "admin.queue.noMatches"))
                .fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                .accessibilityIdentifier("queue-empty")
        }
    }

    private func claim(_ item: ReviewItem) {
        Task {
            try? await session.services.review.claim(item.id)
            await model.load()
        }
    }
}

/// "Offline, last updated 3 min ago".
struct OfflineLine: View {
    @Environment(\.l10n) private var l10n
    let lastUpdated: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Label {
                Text(text(now: context.date)).fanousFont(.label)
            } icon: {
                Image(systemName: "wifi.slash").accessibilityHidden(true)
            }
            .foregroundStyle(Fanous.textSecondary)
            .accessibilityIdentifier("offline")
        }
    }

    private func text(now: Date) -> String {
        guard let lastUpdated else { return l10n("admin.offline") }
        let minutes = max(0, Int(now.timeIntervalSince(lastUpdated) / 60))
        return l10n("admin.offline.updated", minutes.formatted(.number.locale(l10n.language.locale)))
    }
}

/// One row: title, channel and trust, reasons and the time left. Read as one VoiceOver element.
struct QueueRow: View {
    @Environment(\.l10n) private var l10n
    let item: ReviewItem
    let tab: ReviewTab
    let me: String?

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            HStack(alignment: .firstTextBaseline) {
                if item.escalate {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(Fanous.errorText).accessibilityHidden(true)
                }
                Text(item.title ?? l10n("admin.item.untitled")).fanousFont(.label).foregroundStyle(Fanous.textPrimary)
                    .lineLimit(3)
                Spacer(minLength: FanousScale.spacingSm)
                if tab == .actionNeeded { TimeLeft(due: item.slaDueAt) }
            }
            if let channel = item.channelName {
                Text(channelLine(channel)).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
            }
            Text(reasons).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
            if let other = claimedBy {
                Text(l10n("admin.item.beingReviewed", other)).fanousFont(.caption).foregroundStyle(Fanous.accent)
            }
            if tab == .history, let decision = item.decision {
                Text(AdminText.decision(decision, by: item.decidedByName, l10n: l10n)).fanousFont(.caption)
                    .foregroundStyle(Fanous.textSecondary)
            }
        }
        .padding(.vertical, FanousScale.spacingXs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("queue-row-\(item.id)")
    }

    private var claimedBy: String? {
        guard tab == .actionNeeded, let assigned = item.assignedTo, assigned != me else { return nil }
        return item.assignedToName ?? l10n("admin.item.anotherReviewer")
    }

    private func channelLine(_ channel: String) -> String {
        guard let trust = item.channelTrust else { return channel }
        return "\(channel) · \(AdminText.optional("admin.trust.\(trust)", l10n) ?? trust)"
    }

    private var reasons: String {
        var parts: [String] = []
        if item.minor { parts.append(l10n("admin.reason.minor")) }
        if item.nsfw || item.holdCause == .nsfw { parts.append(l10n("admin.hold.nsfw")) }
        if let cause = item.holdCause, cause != .nsfw { parts.append(l10n("admin.hold.\(cause.rawValue)")) }
        if let top = item.topCategory { parts.append(AdminText.category(top, l10n)) }
        if let risk = item.risk { parts.append(l10n("admin.item.risk", AdminText.percent(risk, l10n))) }
        return parts.joined(separator: " · ")
    }
}

/// The SLA countdown. It changes once a minute, so VoiceOver never hears it more often than that.
struct TimeLeft: View {
    @Environment(\.l10n) private var l10n
    let due: Date?

    var body: some View {
        if let due {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let minutes = Int((due.timeIntervalSince(context.date) / 60).rounded(.up))
                let late = minutes <= 0
                Text(late ? l10n("admin.sla.late", (-minutes).formatted()) : l10n("admin.sla.left", minutes.formatted()))
                    .fanousFont(.caption).monospacedDigit()
                    .foregroundStyle(late ? Fanous.errorText : Fanous.textSecondary)
            }
        }
    }
}

/// Small text helpers shared by the screens.
enum AdminText {
    /// The translation, or nil when the catalogue has none (server categories may be new).
    static func optional(_ key: String, _ l10n: L10n) -> String? {
        let value = l10n(key)
        return value.hasPrefix("⟦") ? nil : value
    }

    static func category(_ raw: String, _ l10n: L10n) -> String {
        optional("admin.category.\(raw)", l10n) ?? raw.replacingOccurrences(of: "_", with: " ")
    }

    static func percent(_ score: Double, _ l10n: L10n) -> String {
        score.formatted(.percent.precision(.fractionLength(0)).locale(l10n.language.locale))
    }

    static func decision(_ decision: String, by name: String?, l10n: L10n) -> String {
        let verb = optional("admin.decision.\(decision)", l10n) ?? decision
        guard let name, !name.isEmpty else { return verb }
        return l10n("admin.decision.by", verb, name)
    }

    static func timecode(_ ms: Int, _ l10n: L10n) -> String { DisplayFormat.duration(Double(ms) / 1000, l10n.language) }
}

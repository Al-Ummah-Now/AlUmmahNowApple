import AUNCoreBridge
import AUNDesign
import Charts
import SwiftUI

/// A channel's numbers for a range, each against the period before it, with daily views and top videos.
struct AnalyticsView: View {
    @Environment(\.l10n) private var l10n
    let services: StudioServices
    let channelID: String
    @State private var range: AnalyticsRange = .days28
    @State private var current: ChannelStats?
    @State private var previous: ChannelStats?
    @State private var failed = false
    @State private var opened: VideoStats?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                Picker(l10n("studio.analytics.range"), selection: $range) {
                    ForEach(AnalyticsRange.allCases, id: \.self) {
                        Text(l10n("studio.analytics.days", $0.rawValue.formatted(.number.locale(l10n.language.locale)))).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("analytics-range")
                if failed {
                    ErrorStateView { Task { await load() } }
                } else if let current {
                    tiles(current)
                    chart(current)
                    topVideos(current)
                } else {
                    ThemeLoader().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(FanousScale.spacingLg)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .fanousPage()
        .navigationTitle(l10n("studio.analytics.title"))
        .task(id: range) { await load() }
        .sheet(item: $opened) { video in
            NavigationStack {
                Form { VideoStatsView(services: services, videoID: video.videoID).studioRows() }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .fanousPage()
                    .navigationTitle(video.title)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(l10n("common.dismiss")) { opened = nil } }
                    }
            }
            #if os(macOS)
                .frame(minWidth: 420, minHeight: 360)
            #endif
        }
    }

    private func load() async {
        let periods = range.periods()
        do {
            async let now = services.studio.channelStats(channelID: channelID, period: periods.current)
            async let before = services.studio.channelStats(channelID: channelID, period: periods.previous)
            current = try await now
            previous = try? await before
            failed = false
        } catch {
            AUNLog.studio.error("Analytics failed: \(error)")
            failed = current == nil
        }
    }

    /// Period numbers from the daily series, each against the period before it; lifetime totals underneath.
    private func tiles(_ stats: ChannelStats) -> some View {
        let locale = l10n.language.locale
        func change(_ value: (ChannelStats) -> Double) -> Double? { previous.flatMap { periodChange(value(stats), value($0)) } }
        return VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: FanousScale.spacingMd)], spacing: FanousScale.spacingMd
            ) {
                StatTile(
                    title: l10n("studio.analytics.views"), value: DisplayFormat.count(stats.periodViews, l10n.language),
                    change: change { Double($0.periodViews) })
                StatTile(
                    title: l10n("studio.analytics.watchHours"),
                    value: (stats.watchTime / 3600).formatted(.number.precision(.fractionLength(0...1)).locale(locale)),
                    change: change(\.watchTime))
                StatTile(
                    title: l10n("studio.analytics.newSubscribers"),
                    value: DisplayFormat.count(stats.periodSubscribers, l10n.language),
                    change: change { Double($0.periodSubscribers) })
            }
            Text(
                l10n(
                    "studio.analytics.lifetime", DisplayFormat.count(stats.totalViews, l10n.language),
                    DisplayFormat.count(stats.totalSubscribers, l10n.language),
                    (stats.engagementRate / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(locale)))
            )
            .fanousFont(.caption)
            .foregroundStyle(Fanous.textSecondary)
            .accessibilityIdentifier("analytics-lifetime")
        }
    }

    @ViewBuilder private func chart(_ stats: ChannelStats) -> some View {
        let points = stats.daily.compactMap { metric in metric.day.map { (day: $0, views: metric.views) } }
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                Text(l10n("studio.analytics.dailyViews")).fanousFont(.title).foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Chart(points, id: \.day) { point in
                    BarMark(
                        x: .value(l10n("studio.analytics.day"), point.day, unit: .day),
                        y: .value(l10n("studio.analytics.views"), point.views)
                    )
                    .foregroundStyle(Fanous.primary)
                }
                .frame(height: 180)
                .environment(\.locale, l10n.language.locale)
                .accessibilityIdentifier("analytics-chart")
            }
            .padding(FanousScale.spacingLg)
            .fanousMaterial(.card) { .rounded($0.lg) }
        }
    }

    @ViewBuilder private func topVideos(_ stats: ChannelStats) -> some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            Text(l10n("studio.analytics.topVideos")).fanousFont(.title).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if stats.topVideos.isEmpty {
                Text(l10n("studio.analytics.noVideos")).foregroundStyle(Fanous.textSecondary)
            }
            ForEach(stats.topVideos) { video in
                Button {
                    opened = video
                } label: {
                    HStack {
                        Text(video.title).foregroundStyle(Fanous.textPrimary).lineLimit(2)
                        Spacer()
                        Text(l10n("video.views", DisplayFormat.count(video.views, l10n.language)))
                            .foregroundStyle(Fanous.textSecondary)
                    }
                    .fanousFont(.body)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("top-\(video.videoID)")
                Divider()
            }
        }
        .padding(FanousScale.spacingLg)
        .fanousMaterial(.card) { .rounded($0.lg) }
    }
}

/// One number with its change against the previous period.
struct StatTile: View {
    @Environment(\.l10n) private var l10n
    let title: String
    let value: String
    let change: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            Text(title).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
            Text(value).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
            if let change {
                Text(
                    l10n(
                        "studio.analytics.change",
                        change.formatted(
                            .percent.precision(.fractionLength(0)).sign(strategy: .always()).locale(l10n.language.locale)))
                )
                .fanousFont(.caption)
                .foregroundStyle(change >= 0 ? Fanous.successText : Fanous.errorText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FanousScale.spacingMd)
        .fanousMaterial(.card) { .rounded($0.md) }
        .accessibilityElement(children: .combine)
    }
}

/// A video's numbers for the last 28 days.
struct VideoStatsView: View {
    @Environment(\.l10n) private var l10n
    let services: StudioServices
    let videoID: String
    @State private var stats: VideoStats?
    @State private var failed = false

    var body: some View {
        Group {
            if let stats {
                LabeledContent(l10n("studio.analytics.views"), value: DisplayFormat.count(stats.views, l10n.language))
                LabeledContent(
                    l10n("studio.analytics.watchHours"),
                    value: (stats.watchTime / 3600).formatted(
                        .number.precision(.fractionLength(0...1)).locale(l10n.language.locale)))
                LabeledContent(
                    l10n("studio.analytics.averageView"), value: DisplayFormat.duration(stats.averageViewDuration, l10n.language))
                LabeledContent(l10n("studio.analytics.likes"), value: DisplayFormat.count(stats.likes, l10n.language))
                LabeledContent(l10n("studio.analytics.comments"), value: DisplayFormat.count(stats.comments, l10n.language))
            } else if failed {
                Text(l10n("common.error.load")).foregroundStyle(Fanous.errorText)
            } else {
                ProgressView().accessibilityLabel(l10n("common.loading"))
            }
        }
        .task {
            do {
                stats = try await services.studio.videoStats(videoID: videoID, period: AnalyticsRange.days28.periods().current)
            } catch {
                failed = true
            }
        }
        .accessibilityIdentifier("video-stats")
    }
}

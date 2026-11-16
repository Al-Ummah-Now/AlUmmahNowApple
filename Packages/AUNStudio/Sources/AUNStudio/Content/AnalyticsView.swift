import AUNCoreBridge
import AUNDesign
import Charts
import SwiftUI

/// A channel's numbers for a range, each against the period before it, with daily views and top videos.
struct AnalyticsView: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession
    let channelID: String
    private var services: StudioServices { session.services }
    @State private var range: AnalyticsRange = .days28
    @State private var current: ChannelStats?
    @State private var previous: ChannelStats?
    @State private var phase: LoadPhase = .idle
    @State private var loadID = UUID()
    @State private var opened: VideoStats?
    @State private var metric: ChartMetric = .views

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                Picker(l10n("studio.analytics.range"), selection: $range) {
                    ForEach(AnalyticsRange.allCases, id: \.self) {
                        Text(l10n("studio.analytics.days", DisplayFormat.number($0.rawValue, l10n.language))).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("analytics-range")
                switch phase {
                case .loading where current == nil:
                    ThemeLoader().frame(maxWidth: .infinity, minHeight: 200)
                case .failed:
                    ErrorStateView { Task { await load() } }
                default:
                    if let current {
                        tiles(current)
                        chart(current)
                        topVideos(current)
                    }
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
                Form { stats(video).studioRows() }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .fanousPage()
                    .navigationTitle(video.displayTitle(l10n.language))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(l10n("common.dismiss")) { opened = nil } }
                    }
            }
            #if os(macOS)
                .frame(minWidth: 420, minHeight: 360)
            #endif
        }
    }

    /// One video's numbers; a `feature_off` answer hides Analytics.
    private func stats(_ video: VideoStats) -> some View {
        VideoStatsView(services: services, videoID: video.videoID) { session.featureOff(.analytics) }
    }

    /// Ends in the numbers, an error with Retry, or no Analytics at all (`feature_off`). A load replaced by a newer
    /// range leaves the phase to the newer one.
    private func load() async {
        let periods = range.periods()
        let id = UUID()
        loadID = id
        await LoadPhase.run(from: phase, set: { if loadID == id { phase = $0 } }) {
            async let now = retryingRebuild {
                try await services.studio.channelStats(channelID: channelID, period: periods.current)
            }
            async let before = retryingRebuild {
                try await services.studio.channelStats(channelID: channelID, period: periods.previous)
            }
            current = try await now
            previous = try? await before
            return false
        }
        // Analytics is off for this channel: the tab goes away, with nothing to say.
        if loadID == id, phase == .hidden { session.featureOff(.analytics) }
    }

    /// Period numbers from the daily series, each against the period before it; lifetime totals underneath.
    private func tiles(_ stats: ChannelStats) -> some View {
        func change(_ value: (ChannelStats) -> Double) -> Double? { previous.flatMap { periodChange(value(stats), value($0)) } }
        return VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: FanousScale.spacingMd)], spacing: FanousScale.spacingMd
            ) {
                StatTile(
                    title: l10n("studio.analytics.views"), value: DisplayFormat.count(stats.periodViews, l10n.language),
                    change: change { Double($0.periodViews) })
                StatTile(
                    title: l10n("studio.analytics.watchTime"), value: ChartScale.watchTime(stats.watchTime, l10n.language),
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
                    DisplayFormat.percent(stats.engagementRate / 100, l10n.language, fraction: 0...1))
            )
            .fanousFont(.caption)
            .foregroundStyle(Fanous.textSecondary)
            .accessibilityIdentifier("analytics-lifetime")
        }
    }

    private func chart(_ stats: ChannelStats) -> some View {
        let series = ChartSeries(metric: metric, daily: stats.daily)
        return VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            Text(l10n("studio.analytics.daily")).fanousFont(.title).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Picker(l10n("studio.analytics.metric"), selection: $metric) {
                ForEach(ChartMetric.allCases) { Text(l10n($0.titleKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("analytics-metric")
            DailyChart(series: series)
            DailyTable(series: series)
        }
        .padding(FanousScale.spacingLg)
        .fanousMaterial(.card) { .rounded($0.lg) }
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
                        Text(video.displayTitle(l10n.language)).foregroundStyle(Fanous.textPrimary).lineLimit(2)
                        Spacer()
                        Text(DisplayFormat.views(video.views, l10n))
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
                        DisplayFormat.percent(change, l10n.language, signed: true))
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

/// A video's numbers for the last 28 days, with its daily views.
struct VideoStatsView: View {
    @Environment(\.l10n) private var l10n
    let services: StudioServices
    let videoID: String
    /// The stats API answered 404 `feature_off`; whoever shows this hides it.
    var onFeatureOff: () -> Void = {}
    @State private var stats: VideoStats?
    @State private var phase: LoadPhase = .idle

    var body: some View {
        Group {
            if phase == .ready, let stats {
                let language = l10n.language
                LabeledContent(l10n("studio.analytics.views"), value: DisplayFormat.count(stats.periodViews, language))
                LabeledContent(l10n("studio.analytics.watchTime"), value: ChartScale.watchTime(stats.watchTime, language))
                LabeledContent(
                    l10n("studio.analytics.averageView"), value: DisplayFormat.duration(stats.averageViewDuration, language))
                LabeledContent(l10n("studio.analytics.likes"), value: DisplayFormat.count(stats.periodLikes, language))
                LabeledContent(l10n("studio.analytics.comments"), value: DisplayFormat.count(stats.periodComments, language))
                if !stats.daily.isEmpty {
                    DailyChart(series: ChartSeries(metric: .views, daily: stats.daily), height: 160)
                }
            } else if phase == .failed {
                Text(l10n("common.error.load")).foregroundStyle(Fanous.errorText)
            } else if phase == .empty {
                Text(l10n("studio.analytics.empty.views")).foregroundStyle(Fanous.textSecondary)
            } else if phase == .idle || phase.isLoading {
                // Drawn before the first load too: `.task` never runs on an empty group.
                ProgressView().accessibilityLabel(l10n("common.loading"))
            }
        }
        .task {
            await LoadPhase.run(from: phase, set: { phase = $0 }) {
                stats = try await retryingRebuild {
                    try await services.studio.videoStats(videoID: videoID, period: AnalyticsRange.days28.periods().current)
                }
                return false
            }
            if phase == .hidden { onFeatureOff() }
        }
        .accessibilityIdentifier("video-stats")
    }
}

/// Analytics answers 503 `index_rebuilding` while the ownership index heals: try once more after a few seconds.
func retryingRebuild<T: Sendable>(
    after delay: Duration = .seconds(3), _ load: @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await load()
    } catch CoreError.http(status: 503) {
        try await Task.sleep(for: delay)
        return try await load()
    }
}

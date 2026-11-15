import AUNCoreBridge
import AUNDesign
import Charts
import SwiftUI

/// Preset periods plus "Custom", which shows a from/to pair (UTC days, at most a year).
struct AnalyticsPeriodPicker: View {
    @Environment(\.l10n) private var l10n
    @Binding var period: AnalyticsPeriod

    private enum Choice: Hashable {
        case preset(AnalyticsRange)
        case custom
    }

    private var choice: Binding<Choice> {
        Binding(
            get: { period.preset.map(Choice.preset) ?? .custom },
            set: { choice in
                switch choice {
                case .preset(let range): period = .preset(range)
                case .custom: period = AnalyticsPeriod(preset: nil, from: period.from, to: period.to)
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            Picker(l10n("studio.analytics.range"), selection: choice) {
                ForEach(AnalyticsRange.allCases, id: \.self) {
                    Text(l10n("studio.analytics.days", $0.rawValue.formatted(.number.locale(l10n.language.locale))))
                        .tag(Choice.preset($0))
                }
                Text(l10n("studio.analytics.custom")).tag(Choice.custom)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("analytics-range")
            if period.preset == nil {
                HStack(spacing: FanousScale.spacingMd) {
                    DatePicker(
                        l10n("studio.analytics.from"),
                        selection: Binding(get: { period.from }, set: { period.from = $0 }),
                        in: ...period.to, displayedComponents: .date
                    )
                    .accessibilityIdentifier("analytics-from")
                    DatePicker(
                        l10n("studio.analytics.to"), selection: Binding(get: { period.to }, set: { period.to = $0 }),
                        in: period.from...Date(), displayedComponents: .date
                    )
                    .accessibilityIdentifier("analytics-to")
                }
                .environment(\.locale, l10n.language.locale)
                Text(l10n("studio.analytics.customHint")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
            }
        }
    }
}

/// Lifetime totals of the channel (`/api/analytics/summary`).
struct AllTimeCard: View {
    @Environment(\.l10n) private var l10n
    let summary: AnalyticsSummary

    var body: some View {
        let language = l10n.language
        VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            Text(l10n("studio.analytics.allTime")).fanousFont(.title).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: FanousScale.spacingMd)], spacing: FanousScale.spacingMd
            ) {
                StatTile(
                    title: l10n("studio.analytics.views"), value: DisplayFormat.count(summary.totalViews, language), change: nil)
                StatTile(
                    title: l10n("studio.analytics.subscribers"),
                    value: DisplayFormat.count(summary.totalSubscribers, language), change: nil)
                StatTile(
                    title: l10n("studio.analytics.videos"), value: DisplayFormat.count(summary.totalVideos, language),
                    change: nil)
                StatTile(
                    title: l10n("studio.analytics.likes"), value: DisplayFormat.count(summary.totalLikes, language), change: nil)
                StatTile(
                    title: l10n("studio.analytics.comments"), value: DisplayFormat.count(summary.totalComments, language),
                    change: nil)
                StatTile(
                    title: l10n("studio.analytics.averagePerVideo"),
                    value: DisplayFormat.count(Int(summary.averageViewsPerVideo.rounded()), language), change: nil)
                StatTile(
                    title: l10n("studio.analytics.engagement"),
                    value: (summary.engagementRate / 100).formatted(
                        .percent.precision(.fractionLength(0...1)).locale(language.locale)),
                    change: nil)
            }
        }
        .padding(FanousScale.spacingLg)
        .fanousMaterial(.card) { .rounded($0.lg) }
        .accessibilityIdentifier("analytics-all-time")
    }
}

/// One video over the chosen period: its numbers, views per day and how long viewers keep watching, with CSV export.
struct VideoDeepDiveView: View {
    @Environment(\.l10n) private var l10n
    let services: StudioServices
    let video: VideoStats
    let period: AnalyticsPeriod
    @State private var stats: VideoStats?
    @State private var retention: RetentionCurve?
    @State private var failed = false
    @State private var export: CSVExport?
    @State private var message: StudioMessage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                if let stats {
                    HStack {
                        Spacer()
                        Menu {
                            Button(l10n("studio.analytics.export.daily")) { exportDaily() }
                            Button(l10n("studio.analytics.export.retention")) { exportRetention() }
                                .disabled(retention?.points == nil)
                        } label: {
                            Label(l10n("studio.analytics.export"), systemImage: "square.and.arrow.down")
                        }
                        .fixedSize()
                        .accessibilityIdentifier("video-export")
                    }
                    numbers(stats)
                    VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                        Text(l10n("studio.analytics.daily")).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        let series = ChartSeries(metric: .views, daily: stats.daily)
                        DailyChart(series: series, height: 180)
                        DailyTable(series: series)
                    }
                    .padding(FanousScale.spacingLg)
                    .fanousMaterial(.card) { .rounded($0.lg) }
                    retentionCard
                } else if failed {
                    ErrorStateView { Task { await load() } }
                } else {
                    ThemeLoader().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(FanousScale.spacingLg)
        }
        .fanousPage()
        .navigationTitle(video.title)
        .task { await load() }
        .csvExporter($export) { error in
            AUNLog.studio.error("Saving the CSV failed: \(error)")
            message = ("studio.analytics.export.failed", [])
        }
        .overlay(alignment: .bottom) { MessageBanner(message: $message) }
        .accessibilityIdentifier("video-deep-dive")
    }

    private func load() async {
        let current = period.periods().current
        do {
            async let numbers = retryingRebuild { try await services.studio.videoStats(videoID: video.videoID, period: current) }
            async let curve = retryingRebuild { try await services.insights.retention(videoID: video.videoID, period: current) }
            stats = try await numbers
            retention = try? await curve
            failed = false
        } catch is CancellationError {
        } catch {
            AUNLog.studio.error("Video analytics failed: \(error)")
            failed = stats == nil
        }
    }

    private func numbers(_ stats: VideoStats) -> some View {
        let language = l10n.language
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), spacing: FanousScale.spacingMd)], spacing: FanousScale.spacingMd
        ) {
            StatTile(title: l10n("studio.analytics.views"), value: DisplayFormat.count(stats.periodViews, language), change: nil)
            StatTile(
                title: l10n("studio.analytics.watchTime"), value: ChartScale.watchTime(stats.watchTime, language), change: nil)
            StatTile(
                title: l10n("studio.analytics.averageView"),
                value: DisplayFormat.duration(stats.averageViewDuration, language), change: nil)
            StatTile(title: l10n("studio.analytics.likes"), value: DisplayFormat.count(stats.periodLikes, language), change: nil)
            StatTile(
                title: l10n("studio.analytics.comments"), value: DisplayFormat.count(stats.periodComments, language),
                change: nil)
        }
    }

    private var retentionCard: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            Text(l10n("studio.analytics.retention")).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let retention, let points = retention.points, !points.isEmpty {
                Text(
                    l10n(
                        "studio.analytics.retentionStarts", DisplayFormat.count(retention.starts, l10n.language))
                )
                .fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                RetentionChart(points: points)
            } else {
                Text(l10n("studio.analytics.retentionTooFew")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
            }
        }
        .padding(FanousScale.spacingLg)
        .fanousMaterial(.card) { .rounded($0.lg) }
        .accessibilityIdentifier("video-retention")
    }

    private var stem: String { "\(video.videoID)-\(period.fileStem())" }

    private func exportDaily() {
        guard let stats else { return }
        export = CSVExport(
            file: CSVFile(AnalyticsCSV.daily(stats.daily, header: AnalyticsCSVHeaders.daily(l10n))),
            name: "\(l10n("studio.analytics.export.dailyFile"))-\(stem).csv")
    }

    private func exportRetention() {
        guard let retention else { return }
        export = CSVExport(
            file: CSVFile(AnalyticsCSV.retention(retention, header: AnalyticsCSVHeaders.retention(l10n))),
            name: "\(l10n("studio.analytics.export.retentionFile"))-\(stem).csv")
    }
}

/// Share of viewers still watching across the video, 0–100 % of its length.
struct RetentionChart: View {
    @Environment(\.l10n) private var l10n
    let points: [RetentionCurve.Point]

    var body: some View {
        let locale = l10n.language.locale
        Chart(points) { point in
            AreaMark(
                x: .value(l10n("studio.analytics.csv.position"), point.bucket),
                y: .value(l10n("studio.analytics.csv.watching"), point.share)
            )
            .foregroundStyle(Fanous.accent.opacity(0.18))
            LineMark(
                x: .value(l10n("studio.analytics.csv.position"), point.bucket),
                y: .value(l10n("studio.analytics.csv.watching"), point.share)
            )
            .foregroundStyle(Fanous.accent)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXScale(domain: 0...100)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Fanous.outline)
                AxisValueLabel {
                    if let bucket = value.as(Double.self) {
                        Text((bucket / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                            .foregroundStyle(Fanous.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 0.5, 1]) { value in
                AxisGridLine().foregroundStyle(Fanous.outline)
                AxisValueLabel {
                    if let share = value.as(Double.self) {
                        Text(share.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                            .foregroundStyle(Fanous.textSecondary)
                    }
                }
            }
        }
        .frame(height: 200)
        .accessibilityLabel(l10n("studio.analytics.retention"))
        .accessibilityValue(summary)
    }

    /// The audio-graph-free summary: where half the viewers had left, and how many watched to the end.
    private var summary: String {
        let locale = l10n.language.locale
        let end = points.last?.share ?? 0
        let half = points.first { $0.share < 0.5 }?.bucket
        let endText = end.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        guard let half else { return l10n("studio.analytics.retentionSummaryEnd", endText) }
        return l10n(
            "studio.analytics.retentionSummary", (half / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale)),
            endText)
    }
}

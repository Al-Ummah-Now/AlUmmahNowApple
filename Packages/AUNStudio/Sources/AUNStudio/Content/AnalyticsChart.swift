import AUNCoreBridge
import AUNDesign
import Charts
import SwiftUI

/// What a daily chart shows.
enum ChartMetric: String, CaseIterable, Identifiable {
    case views, watchTime, subscribers

    var id: String { rawValue }
    var titleKey: String { "studio.analytics.metric.\(rawValue)" }
    var emptyKey: String { "studio.analytics.empty.\(rawValue)" }

    func value(_ day: DailyMetric) -> Double {
        switch self {
        case .views: Double(day.views)
        case .watchTime: day.watchTime
        case .subscribers: Double(day.subscribers)
        }
    }
}

/// The numbers one chart draws: one value per UTC day, in order, plus the axis and its labels.
struct ChartSeries: Equatable {
    struct Point: Equatable {
        var day: Date
        var value: Double
    }

    let metric: ChartMetric
    let points: [Point]
    /// Watch time is drawn in minutes or hours; counts as they are.
    let unit: ChartScale.WatchUnit?
    let scale: ValueScale

    init(metric: ChartMetric, daily: [DailyMetric]) {
        self.metric = metric
        let raw = daily.compactMap { day in day.day.map { Point(day: $0, value: metric.value(day)) } }
            .sorted { $0.day < $1.day }
        if metric == .watchTime {
            let unit = ChartScale.watchUnit(largestSeconds: raw.map(\.value).max() ?? 0)
            self.unit = unit
            points = raw.map { Point(day: $0.day, value: $0.value / unit.seconds) }
            scale = ChartScale.nice(points.map(\.value))
        } else {
            unit = nil
            points = raw
            scale = ChartScale.nice(points.map(\.value), integer: true)
        }
    }

    var isEmpty: Bool { points.allSatisfy { $0.value == 0 } }

    /// The plot position of point `index`: in Arabic time runs from the right.
    func position(_ index: Int, rtl: Bool) -> Int { rtl ? points.count - 1 - index : index }

    func index(atPosition position: Int, rtl: Bool) -> Int? {
        let index = rtl ? points.count - 1 - position : position
        return points.indices.contains(index) ? index : nil
    }

    func label(_ value: Double, _ language: AppLanguage) -> String {
        if let unit { return ChartScale.format(value, in: unit, language) }
        return ChartScale.compact(value, language)
    }

    func fullLabel(_ value: Double, _ language: AppLanguage) -> String {
        if let unit { return ChartScale.format(value, in: unit, language) }
        return ChartScale.full(value, language)
    }

    /// "Views from 15 Oct to 11 Nov. Highest: 6,075 on 11 Nov."
    func summary(_ l10n: L10n) -> String {
        let language = l10n.language
        guard let first = points.first, let last = points.last else { return l10n(metric.emptyKey) }
        let from = ChartScale.day(first.day, language)
        let to = ChartScale.day(last.day, language)
        guard !isEmpty, let peak = points.max(by: { $0.value < $1.value }) else {
            return l10n("studio.analytics.summaryEmpty", l10n(metric.titleKey), from, to)
        }
        return l10n(
            "studio.analytics.summary", l10n(metric.titleKey), from, to, fullLabel(peak.value, language),
            ChartScale.day(peak.day, language))
    }
}

/// A daily line chart with a 0-based value axis on round ticks, gridlines, first/middle/last dates, a selection
/// tooltip and the empty text inside the axes. In Arabic the value axis is on the right and time runs from the right.
struct DailyChart: View {
    @Environment(\.l10n) private var l10n
    let series: ChartSeries
    var height: CGFloat = 200
    @State private var selected: Int?

    private var rtl: Bool { l10n.language.isRTL }
    private var language: AppLanguage { l10n.language }

    var body: some View {
        chart
            .frame(height: height)
            // The plot is laid out left to right on purpose; positions and the axis side carry the direction.
            .environment(\.layoutDirection, .leftToRight)
            .overlay {
                if series.isEmpty {
                    Text(l10n(series.metric.emptyKey))
                        .fanousFont(.body)
                        .foregroundStyle(Fanous.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(FanousScale.spacingLg)
                        .accessibilityIdentifier("analytics-empty")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(l10n(series.metric.titleKey))
            .accessibilityValue(series.summary(l10n))
            .accessibilityChartDescriptor(ChartAudioGraph(series: series, l10n: l10n))
            .accessibilityIdentifier("analytics-chart")
    }

    private var chart: some View {
        let count = series.points.count
        let labelled = ChartScale.labelIndices(count).map { series.position($0, rtl: rtl) }
        return Chart {
            ForEach(Array(series.points.enumerated()), id: \.offset) { index, point in
                LineMark(
                    x: .value(l10n("studio.analytics.day"), series.position(index, rtl: rtl)),
                    y: .value(l10n(series.metric.titleKey), point.value)
                )
                .foregroundStyle(Fanous.primary)
                .interpolationMethod(.monotone)
            }
            if let selected, let index = series.index(atPosition: selected, rtl: rtl), !series.isEmpty {
                let point = series.points[index]
                RuleMark(x: .value(l10n("studio.analytics.day"), selected))
                    .foregroundStyle(Fanous.divider)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(point)
                    }
                PointMark(
                    x: .value(l10n("studio.analytics.day"), selected), y: .value(l10n(series.metric.titleKey), point.value)
                )
                .foregroundStyle(Fanous.primary)
            }
        }
        .chartYScale(domain: 0...series.scale.top)
        .chartXScale(domain: 0...max(1, count - 1))
        .chartYAxis {
            AxisMarks(position: rtl ? .trailing : .leading, values: series.scale.ticks) { value in
                AxisGridLine().foregroundStyle(Fanous.divider)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(series.label(number, language)).foregroundStyle(Fanous.textSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: labelled) { value in
                AxisValueLabel(anchor: anchor(value.as(Int.self))) {
                    if let position = value.as(Int.self), let index = series.index(atPosition: position, rtl: rtl) {
                        Text(ChartScale.day(series.points[index].day, language)).foregroundStyle(Fanous.textSecondary)
                    }
                }
            }
        }
        #if !os(tvOS)
            .chartXSelection(value: $selected)
        #endif
    }

    /// Edge labels sit inside the plot, so the first and last dates are never cut off.
    private func anchor(_ position: Int?) -> UnitPoint {
        guard let position, series.points.count > 1 else { return .top }
        if position == 0 { return .topLeading }
        if position == series.points.count - 1 { return .topTrailing }
        return .top
    }

    private func tooltip(_ point: ChartSeries.Point) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ChartScale.day(point.day, language)).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
            Text(series.fullLabel(point.value, language)).fanousFont(.label).foregroundStyle(Fanous.textPrimary)
        }
        .padding(FanousScale.spacingSm)
        .fanousMaterial(.raised) { .rounded($0.sm) }
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .accessibilityIdentifier("analytics-tooltip")
    }
}

/// The same numbers as a table: one row per day, for people who would rather read than look.
struct DailyTable: View {
    @Environment(\.l10n) private var l10n
    let series: ChartSeries

    var body: some View {
        DisclosureGroup(l10n("studio.analytics.table")) {
            ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
                LabeledContent(
                    ChartScale.day(point.day, l10n.language), value: series.fullLabel(point.value, l10n.language))
            }
        }
        .fanousFont(.label)
        .foregroundStyle(Fanous.textPrimary)
        .accessibilityIdentifier("analytics-table")
    }
}

/// VoiceOver's audio graph and data table for a daily chart.
struct ChartAudioGraph: AXChartDescriptorRepresentable {
    let series: ChartSeries
    let l10n: L10n

    func makeChartDescriptor() -> AXChartDescriptor {
        let language = l10n.language
        let days = series.points.map { ChartScale.day($0.day, language) }
        let xAxis = AXCategoricalDataAxisDescriptor(title: l10n("studio.analytics.day"), categoryOrder: days)
        let yAxis = AXNumericDataAxisDescriptor(
            title: l10n(series.metric.titleKey), range: 0...series.scale.top, gridlinePositions: series.scale.ticks
        ) { series.fullLabel($0, language) }
        let data = AXDataSeriesDescriptor(
            name: l10n(series.metric.titleKey), isContinuous: true,
            dataPoints: zip(days, series.points).map { AXDataPoint(x: $0, y: $1.value) })
        return AXChartDescriptor(
            title: l10n(series.metric.titleKey), summary: series.summary(l10n), xAxis: xAxis, yAxis: yAxis,
            additionalAxes: [], series: [data])
    }
}

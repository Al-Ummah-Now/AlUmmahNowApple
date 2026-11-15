import AUNCoreBridge
import AUNDesign
import SwiftUI
import UniformTypeIdentifiers

/// The analytics period: a preset ("last N days") or days the creator picks, each against the same number of days before.
struct AnalyticsPeriod: Hashable, Sendable {
    /// The API keeps a year of daily numbers per request.
    static let maxDays = 365

    var preset: AnalyticsRange?
    var from: Date
    var to: Date

    static func preset(_ range: AnalyticsRange, now: Date = Date()) -> AnalyticsPeriod {
        let current = range.periods(now: now).current
        return AnalyticsPeriod(preset: range, from: current.start, to: current.end)
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    /// Whole UTC days from `from` through `to`, at most `maxDays`, never past `now`; then as many days before them.
    func periods(now: Date = Date()) -> (current: DateInterval, previous: DateInterval) {
        if let preset { return preset.periods(now: now) }
        let calendar = Self.utc
        let lastDay = calendar.startOfDay(for: min(max(from, to), now))
        var start = calendar.startOfDay(for: min(from, to, now))
        let span = (calendar.dateComponents([.day], from: start, to: lastDay).day ?? 0) + 1
        if span > Self.maxDays { start = calendar.date(byAdding: .day, value: -(Self.maxDays - 1), to: lastDay) ?? start }
        let days = min(span, Self.maxDays)
        let endOfLastDay = calendar.date(byAdding: .day, value: 1, to: lastDay)?.addingTimeInterval(-1) ?? lastDay
        let end = min(endOfLastDay, now)
        let previousStart = calendar.date(byAdding: .day, value: -days, to: start) ?? start
        return (
            DateInterval(start: start, end: max(start, end)),
            DateInterval(start: previousStart, end: start.addingTimeInterval(-1))
        )
    }

    /// `2026-10-18_2026-11-14`, for file names.
    func fileStem(now: Date = Date()) -> String {
        let current = periods(now: now).current
        return "\(CSVWriter.day(current.start))_\(CSVWriter.day(current.end))"
    }
}

/// A CSV file for the save panel.
struct CSVFile: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let data: Data

    init(_ csv: CSVWriter) { data = csv.data }

    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// One file ready to save: its bytes and the suggested name.
struct CSVExport: Identifiable {
    let id = UUID()
    let file: CSVFile
    let name: String
}

/// Column names in the app language; the values stay machine-readable.
enum AnalyticsCSVHeaders {
    static func daily(_ l10n: L10n) -> [String] {
        [
            l10n("studio.analytics.csv.date"), l10n("studio.analytics.views"), l10n("studio.analytics.csv.watchSeconds"),
            l10n("studio.analytics.likes"), l10n("studio.analytics.comments"), l10n("studio.analytics.newSubscribers"),
        ]
    }

    static func videos(_ l10n: L10n) -> [String] {
        [
            l10n("studio.analytics.csv.videoID"), l10n("studio.analytics.csv.title"), l10n("studio.analytics.views"),
            l10n("studio.analytics.csv.watchSeconds"), l10n("studio.analytics.csv.averageSeconds"),
            l10n("studio.analytics.likes"), l10n("studio.analytics.comments"), l10n("studio.analytics.csv.engagement"),
        ]
    }

    static func retention(_ l10n: L10n) -> [String] {
        [l10n("studio.analytics.csv.position"), l10n("studio.analytics.csv.watching")]
    }
}

extension View {
    /// Saves `export` through the system save panel, then clears it.
    func csvExporter(_ export: Binding<CSVExport?>, failed: @escaping (any Error) -> Void) -> some View {
        fileExporter(
            isPresented: Binding(get: { export.wrappedValue != nil }, set: { if !$0 { export.wrappedValue = nil } }),
            document: export.wrappedValue?.file, contentType: .commaSeparatedText,
            defaultFilename: export.wrappedValue?.name
        ) { result in
            if case .failure(let error) = result { failed(error) }
            export.wrappedValue = nil
        }
    }
}

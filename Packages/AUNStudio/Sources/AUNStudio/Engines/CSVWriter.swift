import AUNCoreBridge
import Foundation

/// CSV for spreadsheet apps: UTF-8 with a byte-order mark so Excel opens Arabic correctly, RFC 4180 quoting, CRLF line
/// ends, dates as ISO 8601 and numbers without grouping.
public struct CSVWriter: Sendable {
    public private(set) var rows: [[String]] = []

    public init(header: [String]) { rows = [header] }

    public mutating func append(_ row: [String]) { rows.append(row) }

    /// A field quoted when it holds a comma, quote, line break or leading/trailing space. Fields that a spreadsheet
    /// would run as a formula (`=`, `+`, `-`, `@`, tab, CR, LF — including after leading whitespace) get a leading apostrophe.
    public static func field(_ value: String) -> String {
        var text = value
        if isFormulaTrigger(text) {
            text = "'" + text
        }
        let needsQuotes = text.contains { ",\"\n\r".contains($0) } || text.first == " " || text.last == " "
        return needsQuotes ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    private static func isFormulaTrigger(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first else { return false }
        if "=+@\t\r\n".unicodeScalars.contains(first) { return true }
        if first == "-" { return Double(value).map({ !$0.isFinite }) ?? true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lead = trimmed.unicodeScalars.first else { return false }
        if "=+@".unicodeScalars.contains(lead) { return true }
        if lead == "-" { return Double(trimmed).map({ !$0.isFinite }) ?? true }
        return false
    }

    public static func date(_ date: Date) -> String { date.ISO8601Format() }

    /// A day as `YYYY-MM-DD`.
    public static func day(_ date: Date) -> String {
        date.ISO8601Format(.iso8601.year().month().day().dateSeparator(.dash))
    }

    public static func number(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
    }

    public static func number(_ value: Int) -> String { String(value) }

    public var text: String { rows.map { $0.map(Self.field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n" }

    /// The file's bytes, BOM first.
    public var data: Data { Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8) }
}

/// The CSV exports of Studio analytics. Column names follow the app language; values stay machine-readable.
public enum AnalyticsCSV {
    public static func daily(_ days: [DailyMetric], header: [String]) -> CSVWriter {
        var csv = CSVWriter(header: header)
        for day in days {
            csv.append([
                day.day.map(CSVWriter.day) ?? String(day.date.prefix(10)), CSVWriter.number(day.views),
                CSVWriter.number(day.watchTime), CSVWriter.number(day.likes), CSVWriter.number(day.comments),
                CSVWriter.number(day.subscribers),
            ])
        }
        return csv
    }

    public static func videos(_ videos: [VideoStats], header: [String]) -> CSVWriter {
        var csv = CSVWriter(header: header)
        for video in videos {
            csv.append([
                video.videoID, video.title, CSVWriter.number(video.periodViews), CSVWriter.number(video.watchTime),
                CSVWriter.number(video.averageViewDuration), CSVWriter.number(video.periodLikes),
                CSVWriter.number(video.periodComments), CSVWriter.number(video.engagementRate),
            ])
        }
        return csv
    }

    public static func retention(_ curve: RetentionCurve, header: [String]) -> CSVWriter {
        var csv = CSVWriter(header: header)
        for point in curve.points ?? [] { csv.append([CSVWriter.number(point.bucket), CSVWriter.number(point.share)]) }
        return csv
    }
}

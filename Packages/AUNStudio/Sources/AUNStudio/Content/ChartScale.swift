import AUNCoreBridge
import Foundation

/// A 0-based value axis: the ticks from 0 to `top`, ascending.
struct ValueScale: Equatable {
    var top: Double
    var ticks: [Double]
}

/// Value-axis maths and number formats shared with web (`shared-types/chart-scale.ts`), Android (`ChartScale.kt`) and
/// Desktop (`ChartScale.cs`): round ticks on 1, 2, 2.5 and 5 × 10ⁿ, compact labels, watch time in minutes or hours.
enum ChartScale {
    private static let niceSteps: [Double] = [1, 2, 2.5, 5, 10]

    /// About `target` intervals on round numbers. `integer` keeps steps whole, for counts. All zero gives 0…1.
    static func nice(_ values: [Double], target: Int = 4, integer: Bool = false) -> ValueScale {
        let target = Double(max(1, target))
        let largest = values.filter(\.isFinite).max().map { max(0, $0) } ?? 0
        guard largest > 0 else { return ValueScale(top: 1, ticks: [0, 1]) }
        let raw = largest / target
        let magnitude = pow(10, floor(log10(raw)))
        var step = magnitude * (niceSteps.first { $0 * magnitude >= raw } ?? 10)
        if integer { step = max(1, step.rounded(.up)) }
        let count = max(1, Int((largest / step - 1e-9).rounded(.up)))
        let ticks = (0...count).map { round(Double($0) * step) }
        return ValueScale(top: ticks[ticks.count - 1], ticks: ticks)
    }

    private static func round(_ value: Double) -> Double { (value * 1e9).rounded() / 1e9 }

    /// Indices to label on a time axis: the first, the middle and the last.
    static func labelIndices(_ length: Int, count: Int = 3) -> [Int] {
        guard length > 0 else { return [] }
        guard length > count else { return Array(0..<length) }
        let picked = (0..<count).map { Int((Double($0 * (length - 1)) / Double(count - 1)).rounded()) }
        return Array(Set(picked)).sorted()
    }

    /// Chart numbers and dates: Arabic always with Arabic-Indic digits (web `ar-u-nu-arab`).
    static func locale(_ language: AppLanguage) -> Locale {
        Locale(identifier: language == .ar ? "ar@numbers=arab" : language.rawValue)
    }

    /// 1234 → "1.2K" (en), "١٫٢ ألف" (ar).
    static func compact(_ value: Double, _ language: AppLanguage) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale(language)))
    }

    /// A whole number with grouping: "6,075", "٦٬٠٧٥".
    static func full(_ value: Double, _ language: AppLanguage) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(locale(language)))
    }

    enum WatchUnit: Equatable {
        case minute, hour

        var seconds: Double { self == .hour ? 3600 : 60 }
    }

    /// Hours once the largest value reaches two hours, minutes below that.
    static func watchUnit(largestSeconds: Double) -> WatchUnit { largestSeconds >= 2 * 3600 ? .hour : .minute }

    /// A value already in `unit`, with the unit: "3.1 min", "12.5 hr", "٣٫١ د".
    static func format(_ value: Double, in unit: WatchUnit, _ language: AppLanguage) -> String {
        Measurement(value: value, unit: unit == .hour ? UnitDuration.hours : UnitDuration.minutes)
            .formatted(
                .measurement(
                    width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))
                )
                .locale(locale(language)))
    }

    /// Seconds as minutes or hours, the unit picked from the seconds themselves.
    static func watchTime(_ seconds: Double, _ language: AppLanguage) -> String {
        let unit = watchUnit(largestSeconds: seconds)
        return format(seconds / unit.seconds, in: unit, language)
    }

    /// "15 Oct", "١٥ أكتوبر": a UTC day, as the API sends it.
    static func day(_ date: Date, _ language: AppLanguage) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale(language), timeZone: .gmt)
        style = style.day().month(.abbreviated)
        return date.formatted(style)
    }
}

import AUNCoreBridge
import Foundation

/// The one place the apps turn numbers, dates, times, durations, sizes and money into display text.
///
/// Owner decision (2026-11-15): in Arabic every number is shown with Eastern Arabic (Hindi) numerals ٠–٩,
/// whatever the device region or numbering settings say. `AppLanguage.locale` pins the numbering system
/// (`ar@numbers=arab`), and every helper here formats with that locale. English keeps Arabic numerals 0–9.
///
/// Code, ids, URLs, version and build numbers, CSV and wire formats stay as they are and do not use this.
/// Text the user types is normalised back to 0–9 with ``normalizeDigits(_:)``.
/// The `display_format` SwiftLint rule rejects display formatting outside this file.
public enum DisplayFormat {
    /// Any `FormatStyle` in the app language: the escape hatch for styles the helpers below don't cover.
    public static func format<Style: FormatStyle>(_ value: Style.FormatInput, _ style: Style, _ language: AppLanguage) -> String
    where Style.FormatOutput == String {
        style.locale(language.locale).format(value)
    }

    /// A whole number with grouping: "6,075", "٦٬٠٧٥".
    public static func number<Value: BinaryInteger>(_ value: Value, _ language: AppLanguage, grouping: Bool = true) -> String {
        format(value, IntegerFormatStyle<Value>().grouping(grouping ? .automatic : .never), language)
    }

    /// A number with up to `fraction` decimals: "1.5", "١٫٥".
    public static func number(_ value: Double, _ language: AppLanguage, fraction: ClosedRange<Int> = 0...2) -> String {
        format(value, FloatingPointFormatStyle<Double>.number.precision(.fractionLength(fraction)), language)
    }

    /// A short count for views and subscribers: "1.2K", "١٫٢ ألف".
    public static func count<Value: BinaryInteger>(_ value: Value, _ language: AppLanguage) -> String {
        format(value, IntegerFormatStyle<Value>().notation(.compactName), language)
    }

    /// A compact number with up to one decimal (chart axes): "1.2K", "١٫٢ ألف".
    public static func compact(_ value: Double, _ language: AppLanguage) -> String {
        format(value, FloatingPointFormatStyle<Double>.number.notation(.compactName).precision(.fractionLength(0...1)), language)
    }

    /// A fraction (0.25) as a percentage: "25%", "٢٥٪". `signed` adds "+" to gains.
    public static func percent(
        _ fraction: Double, _ language: AppLanguage, fraction digits: ClosedRange<Int> = 0...0, signed: Bool = false
    ) -> String {
        var style = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(digits))
        if signed { style = style.sign(strategy: .always()) }
        return format(fraction, style, language)
    }

    /// A date or time in any `Date.FormatStyle`: "Oct 15, 2026", "١٥ أكتوبر ٢٠٢٦".
    public static func date(_ date: Date, _ style: Date.FormatStyle, _ language: AppLanguage) -> String {
        format(date, style, language)
    }

    /// Day, month and year: "Oct 15, 2026", "١٥ أكتوبر ٢٠٢٦".
    public static func day(_ date: Date, _ language: AppLanguage) -> String {
        self.date(date, .dateTime.day().month().year(), language)
    }

    /// Date and time: "10/15/2026, 9:41 AM", "١٥‏/١٠‏/٢٠٢٦، ٩:٤١ ص".
    public static func dateTime(_ date: Date, _ language: AppLanguage) -> String {
        self.date(date, .dateTime, language)
    }

    /// "3 hr. ago", "قبل ٣ ساعات".
    public static func relative(
        _ date: Date, to now: Date, _ language: AppLanguage,
        unitsStyle: RelativeDateTimeFormatter.UnitsStyle = .short
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.locale
        formatter.unitsStyle = unitsStyle
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// A file size: "1.2 MB", "١٫٢ م.ب".
    public static func bytes(_ count: Int64, _ language: AppLanguage, style: ByteCountFormatStyle.Style = .file) -> String {
        format(count, ByteCountFormatStyle(style: style), language)
    }

    /// Money. Arabic uses the Arabic currency name, never the "US$" symbol: "$12.69", "١٢٫٦٩ دولار أمريكي".
    public static func money(_ amount: Decimal, currency code: String, _ language: AppLanguage) -> String {
        let style = Decimal.FormatStyle.Currency(code: code)
        return format(amount, language == .ar ? style.presentation(.fullName) : style, language)
    }

    /// A playback position or length as a clock: "1:05", "1:02:05", "١:٠٥".
    public static func duration(_ seconds: Double, _ language: AppLanguage) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        func pad(_ value: Int) -> String { (value < 10 ? number(0, language) : "") + number(value, language, grouping: false) }
        if hours > 0 { return "\(number(hours, language, grouping: false)):\(pad(minutes)):\(pad(secs))" }
        return "\(number(minutes, language, grouping: false)):\(pad(secs))"
    }

    /// A timecode label with tenths: "0:15.0", "1:02:05.4", "٠:١٥٫٠".
    public static func timecode(milliseconds: Int, _ language: AppLanguage, fractionDigits: Int = 1) -> String {
        let duration = Duration.milliseconds(max(0, milliseconds))
        let pattern: Duration.TimeFormatStyle.Pattern =
            milliseconds >= 3_600_000
            ? .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: fractionDigits)
            : .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: fractionDigits)
        return format(duration, Duration.TimeFormatStyle(pattern: pattern), language)
    }

    /// Text the user typed, with Eastern Arabic (Hindi) ٠–٩ and Persian ۰–۹ digits turned into 0–9, for
    /// numeric fields, codes and anything parsed as a number.
    public static func normalizeDigits(_ input: String) -> String {
        String(
            String.UnicodeScalarView(
                input.unicodeScalars.map { scalar in
                    switch scalar.value {
                    case 0x0660...0x0669: Unicode.Scalar(scalar.value - 0x0660 + 0x30) ?? scalar
                    case 0x06F0...0x06F9: Unicode.Scalar(scalar.value - 0x06F0 + 0x30) ?? scalar
                    default: scalar
                    }
                }))
    }
}

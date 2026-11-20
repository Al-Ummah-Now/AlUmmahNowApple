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

    /// A short count for views and subscribers: "1.2K", "١٫٢ ألف", «٨ آلاف», «٢ ألفان».
    public static func count<Value: BinaryInteger>(_ value: Value, _ language: AppLanguage) -> String {
        if language == .ar, let arabic = arabicCompact(Double(value)) { return arabic }
        return format(value, IntegerFormatStyle<Value>().notation(.compactName), language)
    }

    /// A compact number with up to one decimal (chart axes): "1.2K", "١٫٢ ألف".
    public static func compact(_ value: Double, _ language: AppLanguage) -> String {
        if language == .ar, let arabic = arabicCompact(value) { return arabic }
        return format(
            value, FloatingPointFormatStyle<Double>.number.notation(.compactName).precision(.fractionLength(0...1)), language)
    }

    /// Arabic thousands, millions and billions, or nil under 1,000. Owner rule (2026-11-20, same as Android): the
    /// number is truncated to one decimal and the scale word agrees with it — whole 1 «ألف», whole 2 «ألفان»,
    /// whole 3–10 «آلاف», 11 and up or any decimal «ألف» (likewise مليون/مليونان/ملايين, مليار/ملياران/مليارات).
    /// CLDR's compact Arabic picks the word from the full count, giving «٢ ألف», «١٠ ألف», «٣ مليون».
    static func arabicCompact(_ value: Double) -> String? {
        let magnitude = abs(value)
        guard magnitude.isFinite, magnitude >= 1000 else { return nil }
        let scales: [(size: Double, one: String, two: String, few: String)] = [
            (1e9, "مليار", "ملياران", "مليارات"),
            (1e6, "مليون", "مليونان", "ملايين"),
            (1e3, "ألف", "ألفان", "آلاف"),
        ]
        guard let scale = scales.first(where: { magnitude >= $0.size }) else { return nil }
        let shown = (magnitude / scale.size * 10).rounded(.towardZero) / 10
        let word: String
        switch shown {
        case 1: word = scale.one
        case 2: word = scale.two
        case 3...10 where shown == shown.rounded(.towardZero): word = scale.few
        default: word = scale.one
        }
        let sign = value < 0 ? "-" : ""
        return sign + number(shown, .ar, fraction: 0...1) + "\u{00A0}" + word
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

    /// Day and month, with the year only when it is not this year: "Nov 6", "٦ نوفمبر", "Nov 6, 2025".
    /// For list rows, where the date sits in its own column and must never wrap.
    public static func shortDay(
        _ date: Date, _ language: AppLanguage, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style: Date.FormatStyle = .dateTime.day().month(.abbreviated)
        return self.date(date, sameYear ? style : style.year(), language)
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

    /// The separator between values on one line. Arabic uses a bullet: a middle dot «·» looks like the Eastern
    /// Arabic zero «٠» next to ٠–٩ numbers.
    public static func separator(_ language: AppLanguage) -> String { language == .ar ? " • " : " · " }

    /// Values on one line ("Al Ummah Now · 1.2K views"), empty ones dropped. Each value is direction-isolated so an
    /// English name inside Arabic text (or the reverse) keeps its order and punctuation; Arabic starts right-to-left.
    public static func meta(_ parts: [String?], _ language: AppLanguage) -> String {
        let values = parts.compactMap { $0 }.filter { !$0.isEmpty }
        let line = values.map(isolate).joined(separator: separator(language))
        return language == .ar && !line.isEmpty ? "\u{200F}" + line : line
    }

    /// Wraps text in FIRST STRONG ISOLATE … POP DIRECTIONAL ISOLATE.
    public static func isolate(_ text: String) -> String { "\u{2068}\(text)\u{2069}" }

    /// The CLDR plural category of a whole number: zero, one, two, few, many or other.
    public static func pluralCategory(_ count: Int, _ language: AppLanguage) -> String {
        let n = abs(count)
        switch language {
        case .en: return n == 1 ? "one" : "other"
        case .ar:
            switch (n, n % 100) {
            case (0, _): return "zero"
            case (1, _): return "one"
            case (2, _): return "two"
            case (_, 3...10): return "few"
            case (_, 11...99): return "many"
            default: return "other"
            }
        }
    }

    /// "1.2K views", «١٫٢ ألف مشاهدة», «مشاهدتان», with the noun agreeing with the count (keys `video.views.*`).
    public static func views(_ count: Int, _ l10n: L10n) -> String {
        // A compact number ("1.2K", «١٫٢ ألف», «٨ آلاف») takes the "other" form in both languages: after ألف/مليون/مليار
        // the Arabic noun is always the singular «مشاهدة»; only counts under 1,000 agree with the full count.
        let category = count >= 1000 ? "other" : pluralCategory(count, l10n.language)
        return l10n("video.views.\(category)", self.count(count, l10n.language))
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

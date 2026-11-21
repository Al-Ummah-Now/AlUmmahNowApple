import AUNCoreBridge
import Foundation

/// The one place the apps turn numbers, dates, times, durations, sizes and money into display text.
///
/// Owner decision (2026-11-15): in Arabic every number is shown with Eastern Arabic (Hindi) numerals ٠–٩,
/// whatever the device region or numbering settings say. `AppLanguage.locale` pins the numbering system
/// (`ar@numbers=arab`), and every helper here formats with that locale. English keeps Arabic numerals 0–9.
///
/// Arabic numbers are never grouped («٦٠٧٥», not «٦٬٠٧٥»): SF Arabic draws the thousands mark «٬» and the decimal mark
/// «٫» as the same comma, so «٢٠٬٣٢٥» beside «١٢٨٫٨ ألف» read alike. Without grouping the only such mark is the
/// decimal one. Large values are compact (ألف، م), so ungrouped numbers stay short. English keeps "6,075".
///
/// Code, ids, URLs, version and build numbers, CSV and wire formats stay as they are and do not use this.
/// Text the user types is normalised back to 0–9 with ``normalizeDigits(_:)``.
/// The `display_format` SwiftLint rule rejects display formatting outside this file.
public enum DisplayFormat {
    /// Any `FormatStyle` in the app language: the escape hatch for styles the helpers below don't cover.
    public static func format<Style: FormatStyle>(_ value: Style.FormatInput, _ style: Style, _ language: AppLanguage) -> String
    where Style.FormatOutput == String {
        let text = style.locale(language.locale).format(value)
        return language == .ar ? text.replacingOccurrences(of: arabicGroupingMark, with: "") : text
    }

    /// U+066C ARABIC THOUSANDS SEPARATOR, which no Arabic text from here carries.
    static let arabicGroupingMark = "\u{066C}"

    /// A whole number, grouped in English only: "6,075", «٦٠٧٥».
    public static func number<Value: BinaryInteger>(_ value: Value, _ language: AppLanguage, grouping: Bool = true) -> String {
        format(value, IntegerFormatStyle<Value>().grouping(grouping ? .automatic : .never), language)
    }

    /// A number with up to `fraction` decimals: "1.5", "١٫٥".
    public static func number(_ value: Double, _ language: AppLanguage, fraction: ClosedRange<Int> = 0...2) -> String {
        format(value, FloatingPointFormatStyle<Double>.number.precision(.fractionLength(fraction)), language)
    }

    /// A short count for views and subscribers: "1.2K", "33.6K", "١٫٢ ألف", «ألف», «ألفان», «٨ آلاف».
    public static func count<Value: BinaryInteger>(_ value: Value, _ language: AppLanguage) -> String {
        compactCount(Double(value), language) ?? format(value, IntegerFormatStyle<Value>(), language)
    }

    /// A compact number with up to one decimal (chart axes): "1.2K", "١٫٢ ألف".
    public static func compact(_ value: Double, _ language: AppLanguage) -> String {
        compactCount(value, language)
            ?? format(value, FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1)), language)
    }

    /// Thousands, millions and billions in either language, or nil under 1,000. Both languages show the same number:
    /// truncated to one decimal, a trailing ".0" dropped (33,600 → "33.6K", «٣٣٫٦ ألف»; 1,299 → "1.2K"), as on Android.
    /// Foundation's compact notation rounds instead and drops the decimal from 10K up ("34K", "21K").
    static func compactCount(_ value: Double, _ language: AppLanguage) -> String? {
        switch language {
        case .ar: return arabicCompact(value)
        case .en:
            guard let (shown, scale) = truncatedScale(value) else { return nil }
            let suffix = [1e9: "B", 1e6: "M", 1e3: "K"][scale] ?? ""
            return (value < 0 ? "-" : "") + number(shown, .en, fraction: 0...1) + suffix
        }
    }

    /// The Arabic millions mark, after the number in every form: «١ م», «١٫٢ م مشاهدة».
    static let millionMark = "م"

    /// The magnitude in thousands, millions or billions, truncated to one decimal, with its scale; nil under 1,000.
    /// Multiplies before dividing so whole counts never land just under a tenth (1,300 → 1.3, not 1.2).
    static func truncatedScale(_ value: Double) -> (shown: Double, scale: Double)? {
        let magnitude = abs(value)
        guard magnitude.isFinite, magnitude >= 1000 else { return nil }
        guard let scale = [1e9, 1e6, 1e3].first(where: { magnitude >= $0 }) else { return nil }
        return ((magnitude * 10 / scale).rounded(.towardZero) / 10, scale)
    }

    /// Arabic thousands, millions and billions, or nil under 1,000. Owner rules (2026-11-20 and 2026-11-21, the same
    /// on Android, Apple, Desktop and web): the number is truncated to one decimal, never rounded up. Thousands and
    /// billions take a word that agrees with it: exactly 1 is the word alone («ألف»), exactly 2 the dual alone —
    /// «ألفان» on its own, the construct «ألفا» before a noun (`beforeNoun`), never after a digit — whole 3–10
    /// «٣ آلاف», and 11 and up or any decimal «١١ ألف», «١٫٣ ألف»; likewise مليار/ملياران/مليارات. On its own (a tile,
    /// a chart tick), a whole number ending in 11–99 takes the accusative: «١٢ ألفًا», «١٢٠ ألفًا», «١٢ مليارًا»; before
    /// a noun it stays «١٢ ألف مشاهدة», and 100 or a decimal stays «١٠٠ ألف», «١١٫٥ ألف». Millions are always the
    /// number and «م»: «١ م», «٢ م», «١٫٢ م مشاهدة», «١٥ م». CLDR's compact Arabic picks the word from the full count
    /// instead, giving «٢ ألف», «١٠ ألف».
    static func arabicCompact(_ value: Double, beforeNoun: Bool = false) -> String? {
        guard let (shown, size) = truncatedScale(value) else { return nil }
        let digits = number(shown, .ar, fraction: 0...1)
        if size == 1e6 { return (value < 0 ? "-" : "") + digits + "\u{00A0}" + millionMark }
        let scales: [Double: (one: String, two: String, twoConstruct: String, few: String, accusative: String)] = [
            1e9: ("مليار", "ملياران", "مليارا", "مليارات", "مليارًا"),
            1e3: ("ألف", "ألفان", "ألفا", "آلاف", "ألفًا"),
        ]
        guard let scale = scales[size] else { return nil }
        let whole = shown == shown.rounded(.towardZero)
        let text: String
        switch shown {
        case 1: text = scale.one
        case 2: text = beforeNoun ? scale.twoConstruct : scale.two
        case 3...10 where whole: text = digits + "\u{00A0}" + scale.few
        case _ where whole && !beforeNoun && (11...99).contains(Int(shown) % 100):
            text = digits + "\u{00A0}" + scale.accusative
        default: text = digits + "\u{00A0}" + scale.one
        }
        return (value < 0 ? "-" : "") + text
    }

    /// A fraction (0.25) as a percentage: "25%", "٢٥٪". `signed` adds "+" to gains.
    public static func percent(
        _ fraction: Double, _ language: AppLanguage, fraction digits: ClosedRange<Int> = 0...0, signed: Bool = false
    ) -> String {
        var style = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(digits))
        if signed { style = style.sign(strategy: .always()) }
        return format(fraction, style, language)
    }

    /// A date or time in any `Date.FormatStyle`: "Oct 15, 2026", "١٥ أكتوبر ٢٠٢٦". Always the Gregorian calendar, as
    /// on the web: a device set to an Arabic region (ar_SA) would otherwise show Hijri dates in Arabic only, so the
    /// two languages would disagree («٢ جمادى الآخرة» beside "Nov 12").
    public static func date(_ date: Date, _ style: Date.FormatStyle, _ language: AppLanguage) -> String {
        var style = style
        style.calendar = gregorian
        return format(date, style, language)
    }

    /// The Gregorian calendar every displayed date uses.
    public static let gregorian = Calendar(identifier: .gregorian)

    /// Day, month and year: "Oct 15, 2026", "١٥ أكتوبر ٢٠٢٦".
    public static func day(_ date: Date, _ language: AppLanguage) -> String {
        self.date(date, .dateTime.day().month().year(), language)
    }

    /// Day and month, with the year only when it is not this year: "Nov 6", "٦ نوفمبر", "Nov 6, 2025", «٦ نوفمبر ٢٠٢٥».
    /// For list rows, where the date sits in its own column and must never wrap. Arabic drops CLDR's comma before the
    /// year («٦ نوفمبر، ٢٠٢٥»): rows join values with «، », so it would split one date into two values.
    public static func shortDay(
        _ date: Date, _ language: AppLanguage, now: Date = .now, calendar: Calendar = gregorian
    ) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style: Date.FormatStyle = .dateTime.day().month(.abbreviated)
        let text = self.date(date, sameYear ? style : style.year(), language)
        return language == .ar ? text.replacingOccurrences(of: "،", with: "") : text
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
        formatter.calendar = gregorian
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

    /// The separator between values on one line. Arabic uses the Arabic comma «، »: a dot of any size between values
    /// reads as the Eastern Arabic zero «٠» («عام • ١٢ ألف» as «١٢٠ ألف»).
    public static func separator(_ language: AppLanguage) -> String { language == .ar ? "، " : " · " }

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
    public static func views(_ count: Int, _ l10n: L10n) -> String { counted(count, "video.views", l10n) }

    /// "1.2K subscribers", «ألفا مشترك», «٣ مشتركين» (keys `count.subscribers.*`).
    public static func subscribers(_ count: Int, _ l10n: L10n) -> String { counted(count, "count.subscribers", l10n) }

    /// "7 days", «٧ أيام», «٢٨ يومًا», «يومان», with the noun agreeing with the count (keys `count.days.*`).
    public static func days(_ count: Int, _ l10n: L10n) -> String { counted(count, "count.days", l10n) }

    /// A count with its noun from the plural keys `<key>.zero|one|two|few|many|other`.
    static func counted(_ count: Int, _ key: String, _ l10n: L10n) -> String {
        // A compact number ("1.2K", «١٫٢ ألف», «٨ آلاف») takes the "other" form in both languages: after ألف/م/مليار
        // the Arabic noun is always singular («ألف مشاهدة», «ألفا مشاهدة»); only counts under 1,000 agree with the
        // full count.
        let category = count >= 1000 ? "other" : pluralCategory(count, l10n.language)
        let number =
            l10n.language == .ar
            ? arabicCompact(Double(count), beforeNoun: true) ?? self.count(count, .ar) : self.count(count, l10n.language)
        return l10n("\(key).\(category)", number)
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

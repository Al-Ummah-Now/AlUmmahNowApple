import AUNCoreBridge
import Foundation
import Testing

@testable import AUNDesign

/// Owner decision 2026-11-15: Arabic shows Eastern Arabic (Hindi) numerals ٠–٩ everywhere, English keeps Arabic
/// numerals 0–9, whatever the device region or numbering settings.
@Suite struct DisplayFormatTests {
    static let asciiDigits = CharacterSet(charactersIn: "0123456789")
    static let date = Date(timeIntervalSince1970: 1_792_051_200)  // 2026-10-15 UTC

    /// Every helper, in one language.
    static func samples(_ language: AppLanguage) -> [String] {
        [
            DisplayFormat.number(1_234_567, language),
            DisplayFormat.number(1.5, language),
            DisplayFormat.count(13_607, language),
            DisplayFormat.compact(6075, language),
            DisplayFormat.percent(0.256, language, fraction: 0...1),
            DisplayFormat.percent(0.12, language, signed: true),
            DisplayFormat.day(date, language),
            DisplayFormat.shortDay(date, language, now: date),
            DisplayFormat.dateTime(date, language),
            DisplayFormat.relative(date.addingTimeInterval(-3 * 3600), to: date, language),
            DisplayFormat.bytes(123_456_789, language),
            DisplayFormat.money(Decimal(string: "12.69")!, currency: "USD", language),
            DisplayFormat.duration(3661, language),
            DisplayFormat.timecode(milliseconds: 15_000, language),
            DisplayFormat.timecode(milliseconds: 3_725_400, language),
            L10n(language)("studio.analytics.days", DisplayFormat.number(28, language)),
            L10n(language)("player.skipForward", DisplayFormat.number(10, language)),
        ]
    }

    @Test(arguments: samples(.ar))
    func arabicHasNoArabicNumerals(_ text: String) {
        #expect(text.rangeOfCharacter(from: Self.asciiDigits) == nil, "\(text)")
        #expect(text.unicodeScalars.contains { (0x0660...0x0669).contains($0.value) }, "\(text)")
    }

    @Test func arabicMoneyUsesTheArabicCurrencyName() {
        let text = DisplayFormat.money(Decimal(string: "12.69")!, currency: "USD", .ar)
        #expect(!text.contains("US$") && !text.contains("$"))
        #expect(text.contains("١٢٫٦٩"))
    }

    @Test func englishIsUnchanged() {
        #expect(DisplayFormat.number(1_234_567, .en) == "1,234,567")
        #expect(DisplayFormat.percent(0.25, .en) == "25%")
        #expect(DisplayFormat.percent(0.12, .en, signed: true) == "+12%")
        #expect(DisplayFormat.money(Decimal(string: "12.69")!, currency: "USD", .en) == "$12.69")
        #expect(DisplayFormat.duration(3661, .en) == "1:01:01")
        #expect(DisplayFormat.timecode(milliseconds: 15_000, .en) == "0:15.0")
        for text in Self.samples(.en) { #expect(!text.unicodeScalars.contains { (0x0660...0x0669).contains($0.value) }) }
    }

    @Test func arabicExamples() {
        #expect(DisplayFormat.number(6075, .ar) == "٦٬٠٧٥")
        #expect(DisplayFormat.duration(75, .ar) == "١:١٥")
        #expect(DisplayFormat.timecode(milliseconds: 15_000, .ar) == "٠:١٥٫٠")
    }

    @Test func pinnedLocaleIgnoresTheDeviceNumberingSystem() {
        #expect(AppLanguage.ar.locale.numberingSystem.identifier == "arab")
        #expect(AppLanguage.en.locale.numberingSystem.identifier == "latn")
    }

    @Test func inputDigitsAreNormalised() {
        #expect(DisplayFormat.normalizeDigits("١٢٣٤٥٦٧٨٩٠") == "1234567890")
        #expect(DisplayFormat.normalizeDigits("۱۲۳") == "123")
        #expect(DisplayFormat.normalizeDigits("abc 42 ٤٢") == "abc 42 42")
    }

    @Test func arabicViewsPutTheNumberFirstAndAgree() {
        // Foundation isolates `%@` arguments (FSI…PDI) and compact numbers use a no-break space; compare the visible text.
        func views(_ count: Int, _ l10n: L10n) -> String {
            DisplayFormat.views(count, l10n).replacingOccurrences(of: "\u{2068}", with: "")
                .replacingOccurrences(of: "\u{2069}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        let ar = L10n(.ar)
        #expect(views(1200, ar) == "١٫٢ ألف مشاهدة")
        #expect(views(0, ar) == "لا مشاهدات")
        #expect(views(1, ar) == "مشاهدة واحدة")
        #expect(views(2, ar) == "مشاهدتان")
        #expect(views(5, ar) == "٥ مشاهدات")
        #expect(views(40, ar) == "٤٠ مشاهدة")
        #expect(views(1, L10n(.en)) == "1 view")
        #expect(views(1200, L10n(.en)) == "1.2K views")
    }

    /// Owner rule 2026-11-20 (same on Android, Apple, Desktop, web): under 1,000 the noun agrees with the full count;
    /// from 1K the noun is the singular «مشاهدة» and the scale word agrees with the number shown (one decimal,
    /// truncated). Exactly 1 and 2 drop the digit; 2 before a noun is the construct «ألفا», never a digit + dual.
    static let viewCases: [(count: Int, ar: String, en: String)] = [
        (1, "مشاهدة واحدة", "1 view"),
        (2, "مشاهدتان", "2 views"),
        (3, "٣ مشاهدات", "3 views"),
        (8, "٨ مشاهدات", "8 views"),
        (10, "١٠ مشاهدات", "10 views"),
        (11, "١١ مشاهدة", "11 views"),
        (100, "١٠٠ مشاهدة", "100 views"),
        (1_000, "ألف مشاهدة", "1K views"),
        (1_300, "١٫٣ ألف مشاهدة", "1.3K views"),
        (1_310, "١٫٣ ألف مشاهدة", "1.3K views"),
        (2_000, "ألفا مشاهدة", "2K views"),
        (2_500, "٢٫٥ ألف مشاهدة", "2.5K views"),
        (3_000, "٣ آلاف مشاهدة", "3K views"),
        (8_000, "٨ آلاف مشاهدة", "8K views"),
        (8_020, "٨ آلاف مشاهدة", "8K views"),
        (11_000, "١١ ألف مشاهدة", "11K views"),
        (12_000, "١٢ ألف مشاهدة", "12K views"),
        (1_000_000, "مليون مشاهدة", "1M views"),
        (1_200_000, "١٫٢ مليون مشاهدة", "1.2M views"),
        (2_000_000, "مليونا مشاهدة", "2M views"),
        (3_000_000, "٣ ملايين مشاهدة", "3M views"),
        (15_000_000, "١٥ مليون مشاهدة", "15M views"),
        (2_000_000_000, "مليارا مشاهدة", "2B views"),
        (3_000_000_000, "٣ مليارات مشاهدة", "3B views"),
    ]

    static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2068}", with: "").replacingOccurrences(of: "\u{2069}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test(arguments: viewCases.indices)
    func viewCountsAgreeInBothLanguages(_ index: Int) {
        let item = Self.viewCases[index]
        #expect(Self.visible(DisplayFormat.views(item.count, L10n(.ar))) == item.ar)
        #expect(Self.visible(DisplayFormat.views(item.count, L10n(.en))) == item.en)
    }

    /// Compact numbers without a noun (tiles, chart ticks): the dual stands alone.
    static let tickCases: [(value: Double, ar: String, en: String)] = [
        (500, "٥٠٠", "500"),
        (1_000, "ألف", "1K"),
        (1_500, "١٫٥ ألف", "1.5K"),
        (2_000, "ألفان", "2K"),
        (3_000, "٣ آلاف", "3K"),
        (2_000_000, "مليونان", "2M"),
    ]

    @Test(arguments: tickCases.indices)
    func compactLabelsWithoutANoun(_ index: Int) {
        let item = Self.tickCases[index]
        #expect(Self.visible(DisplayFormat.compact(item.value, .ar)) == item.ar)
        #expect(Self.visible(DisplayFormat.compact(item.value, .en)) == item.en)
        #expect(Self.visible(DisplayFormat.count(Int(item.value), .ar)) == item.ar)
        #expect(Self.visible(DisplayFormat.count(Int(item.value), .en)) == item.en)
    }

    /// English and Arabic show the same number: truncated to one decimal, ".0" dropped (as on Android).
    static let truncationCases: [(value: Int, en: String, ar: String)] = [
        (1_299, "1.2K", "١٫٢ ألف"),
        (1_300, "1.3K", "١٫٣ ألف"),
        (33_600, "33.6K", "٣٣٫٦ ألف"),
        (20_600, "20.6K", "٢٠٫٦ ألف"),
        (999_999, "999.9K", "٩٩٩٫٩ ألف"),
        (1_250_000, "1.2M", "١٫٢ مليون"),
        (15_000_000, "15M", "١٥ مليون"),
        (12_000, "12K", "١٢ ألف"),
        (999, "999", "٩٩٩"),
    ]

    @Test(arguments: truncationCases.indices)
    func compactCountsTruncateTheSameInBothLanguages(_ index: Int) {
        let item = Self.truncationCases[index]
        #expect(Self.visible(DisplayFormat.count(item.value, .en)) == item.en)
        #expect(Self.visible(DisplayFormat.count(item.value, .ar)) == item.ar)
        #expect(Self.visible(DisplayFormat.compact(Double(item.value), .en)) == item.en)
        #expect(Self.visible(DisplayFormat.views(item.value, L10n(.en))) == "\(item.en) views")
    }

    @Test func subscribersAgreeLikeViews() {
        let ar = L10n(.ar)
        #expect(Self.visible(DisplayFormat.subscribers(1, ar)) == "مشترك واحد")
        #expect(Self.visible(DisplayFormat.subscribers(5, ar)) == "٥ مشتركين")
        #expect(Self.visible(DisplayFormat.subscribers(2_000, ar)) == "ألفا مشترك")
        #expect(Self.visible(DisplayFormat.subscribers(2_000, L10n(.en))) == "2K subscribers")
        #expect(
            Self.visible(ar("studio.analytics.lifetime", DisplayFormat.views(2_000, ar), DisplayFormat.subscribers(3, ar), "٥٪"))
                == "منذ البداية: ألفا مشاهدة • ٣ مشتركين • تفاعل ٥٪")
    }

    @Test func arabicScaleWordAgreesWithTheShownNumber() {
        let ar: (Int) -> String = { Self.visible(DisplayFormat.count($0, .ar)) }
        #expect(ar(1_050) == "ألف")  // truncated to 1.0
        #expect(ar(1_990) == "١٫٩ ألف")  // truncated, not rounded to «ألفان»
        #expect(ar(2_050) == "ألفان")
        #expect(ar(10_050) == "١٠ آلاف")
        #expect(ar(10_999) == "١٠٫٩ ألف")
        #expect(ar(11_000) == "١١ ألف")
        #expect(ar(999_999) == "٩٩٩٫٩ ألف")
        #expect(ar(1_000_000) == "مليون")
        #expect(ar(2_500_000_000) == "٢٫٥ مليار")
        #expect(ar(2_000_000_000) == "ملياران")
        #expect(ar(7_000_000_000) == "٧ مليارات")
        #expect(ar(999) == "٩٩٩")
        #expect(DisplayFormat.count(8_020, .en) == "8K")
    }

    @Test func arabicSeparatorIsNotMistakenForZero() {
        let line = DisplayFormat.meta(["عام", "١٫٥ ألف مشاهدة", nil, ""], .ar)
        #expect(!line.contains("·"))
        #expect(line.contains(" • "))
        #expect(line.hasPrefix("\u{200F}"))
        #expect(
            DisplayFormat.meta(["Al Ummah Now", "1.2K views"], .en) == "\u{2068}Al Ummah Now\u{2069} · \u{2068}1.2K views\u{2069}"
        )
        #expect(!L10n(.ar)("studio.analytics.lifetime", "١", "٢", "٣").contains("·"))
    }
}

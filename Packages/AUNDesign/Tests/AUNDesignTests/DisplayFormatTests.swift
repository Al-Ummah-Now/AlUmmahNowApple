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

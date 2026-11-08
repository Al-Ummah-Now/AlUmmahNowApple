import AUNCoreBridge
import Foundation
import Testing

@testable import AUNDesign

@Suite struct DesignTests {
    @Test func enAndArHaveIdenticalKeys() {
        let en = L10n(.en).allKeys
        let ar = L10n(.ar).allKeys
        #expect(!en.isEmpty)
        #expect(en == ar)
    }

    @Test func looksUpByExplicitLanguage() {
        #expect(L10n(.en)("home.title") == "Home")
        #expect(L10n(.ar)("home.title") == "الرئيسية")
    }

    @Test func missingKeysAreVisible() {
        #expect(L10n(.en)("nope") == "⟦nope⟧")
    }

    @Test(arguments: [FanousPalette.dark, FanousPalette.light])
    func paletteMeetsWCAGAA(_ palette: FanousPalette) {
        #expect(palette.textPrimary.contrast(with: palette.background) >= 4.5)
        #expect(palette.textPrimary.contrast(with: palette.surface) >= 4.5)
        #expect(palette.textSecondary.contrast(with: palette.background) >= 4.5)
        #expect(palette.textSecondary.contrast(with: palette.surface) >= 4.5)
        #expect(palette.accentText.contrast(with: palette.background) >= 4.5)
        #expect(palette.onAccent.contrast(with: palette.accent) >= 4.5)
        #expect(palette.error.contrast(with: palette.background) >= 4.5)
    }

    @Test func durationUsesLocaleDigits() {
        #expect(DisplayFormat.duration(75, .en) == "1:15")
        #expect(DisplayFormat.duration(3661, .en) == "1:01:01")
        #expect(DisplayFormat.duration(75, .ar) == "1:15")  // Eastern Arabic digits become an explicit setting (spec §3).
    }

    @MainActor @Test func defaultsToArabicOnlyWhenPreferredFirst() {
        #expect(AppSettings.language(from: ["ar-SA", "en"]) == .ar)
        #expect(AppSettings.language(from: ["fr", "en", "ar"]) == .en)
        #expect(AppSettings.language(from: ["fr"]) == .en)
    }

    @MainActor @Test func persistsLanguage() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let settings = AppSettings(defaults: defaults, preferredLanguages: ["en"])
        settings.language = .ar
        #expect(AppSettings(defaults: defaults, preferredLanguages: ["en"]).language == .ar)
    }
}

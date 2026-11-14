import AUNCoreBridge
import CoreText
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

    static let everyTheme = FanousThemeID.allCases.flatMap { [FanousTheme($0, dark: false), FanousTheme($0, dark: true)] }

    @Test(arguments: everyTheme)
    func everySiteThemeMeetsWCAGAA(_ theme: FanousTheme) {
        let c = theme.colors
        let label = "\(theme.id) dark=\(theme.isDark)"
        let roles = [
            (c.textPrimary, "textPrimary"), (c.textSecondary, "textSecondary"), (c.link, "link"), (c.errorText, "errorText"),
        ]
        for (text, name) in roles {
            #expect(text.contrast(with: c.background) >= 4.5, "\(label) \(name) on background")
            #expect(text.contrast(with: c.surface) >= 4.5, "\(label) \(name) on surface")
        }
        #expect(c.onPrimary.contrast(with: c.primary) >= 4.5, "\(label) onPrimary")
    }

    @Test(arguments: everyTheme)
    func goldPrimaryActionTextPassesOnEveryStopOfThePrimaryMaterial(_ theme: FanousTheme) {
        let text = theme.parts.buttonPrimaryText
        for fills in [theme.material.primary, theme.material.primaryHover, theme.material.primaryPress] {
            for fill in fills {
                let colors: [FanousRGBA]
                switch fill {
                case .solid(let color): colors = [color]
                case .linear(_, _, let stops), .radial(_, _, _, _, let stops): colors = stops.map(\.color)
                }
                for color in colors {
                    #expect(text.contrast(with: color.over(theme.colors.background)) >= 7, "\(theme.id) dark=\(theme.isDark)")
                }
            }
        }
    }

    @Test func fallbackIsFawanees() {
        #expect(FanousThemeID.fallback == .fawanees)
        #expect(FanousThemeID(siteValue: nil) == .fawanees)
        #expect(FanousThemeID(siteValue: "retro") == .fawanees)
        #expect(FanousThemeID(siteValue: "zujaj") == .zujaj)
    }

    @Test func themesKeepTheirOwnTypeface() {
        #expect(FanousTypeface.family(FanousThemeID.nahas.tokens.font.latin) == "Source Serif 4")
        #expect(FanousTypeface.family(FanousThemeID.nahas.tokens.font.arabic) == "Amiri")
        #expect(FanousTypeface.family(FanousThemeID.zujaj.tokens.font.arabic) == "Noto Kufi Arabic")
        #expect(FanousTypeface.family(FanousThemeID.fawanees.tokens.font.latin) == nil)
    }

    @Test func bundledFontsRegister() throws {
        FanousTypeface.register()
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        #expect(urls.count == 5)
    }

    /// Text views ask for their line spacing on every body pass; the font lookup behind it must run once per style,
    /// or a screen of text keeps the main thread busy for seconds at launch and after a language change.
    @Test(.serialized, arguments: [nil, "Source Serif 4", "Amiri", "Noto Kufi Arabic", "Inter"] as [String?])
    func lineSpacingIsMeasuredOncePerStyle(_ family: String?) {
        let style = FanousTypeStyle(size: 17.25, weight: 400, lineHeight: 1.61, letterSpacing: 0)
        let first = FanousTypeface.extraLeading(family: family, style: style)
        let measured = FanousTypeface.measuredLeadings
        for _ in 0..<500 { #expect(FanousTypeface.extraLeading(family: family, style: style) == first) }
        #expect(FanousTypeface.measuredLeadings == measured)
        #expect(first >= 0 && first < style.size)
    }

    @Test(arguments: ["Source Serif 4", "Amiri", "Noto Kufi Arabic", "Inter"])
    func lineSpacingUsesTheBundledFace(_ family: String) {
        FanousTypeface.register()
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 17, nil)
        #expect(CTFontCopyFamilyName(font) as String == family)
    }

    @Test func linearGradientsFollowTheCSSGradientLine() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let down = FanousPaint.linearPoints(angle: 180, in: rect)
        #expect(abs(down.start.y) < 0.001 && abs(down.end.y - 100) < 0.001 && abs(down.start.x - 100) < 0.001)
        let end = FanousPaint.linearPoints(angle: 90, in: rect)
        #expect(abs(end.start.x) < 0.001 && abs(end.end.x - 200) < 0.001)
        // 45deg reaches the corners: half-length is (w·sin + h·cos) / 2.
        let diag = FanousPaint.linearPoints(angle: 45, in: rect)
        #expect(abs(hypot(diag.end.x - diag.start.x, diag.end.y - diag.start.y) - 150 * 2.squareRoot()) < 0.001)
    }

    @Test func radialExtentsFollowCSS() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let c = CGPoint(x: 50, y: 50)
        #expect(FanousPaint.radialRadii(circle: true, extent: .closestSide, center: c, in: rect) == (50, 50))
        #expect(FanousPaint.radialRadii(circle: false, extent: .farthestSide, center: c, in: rect) == (150, 50))
        let corner = FanousPaint.radialRadii(circle: true, extent: .farthestCorner, center: c, in: rect)
        #expect(abs(corner.0 - hypot(150, 50)) < 0.001)
        #expect(FanousPaint.radialRadii(circle: false, extent: .radii(0.5, 0.25), center: c, in: rect) == (100, 25))
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

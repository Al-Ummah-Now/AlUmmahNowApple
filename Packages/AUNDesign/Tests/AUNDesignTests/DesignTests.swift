import AUNCoreBridge
import CoreText
import Foundation
import Testing

@testable import AUNDesign

#if os(iOS)
    import UIKit
#endif

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

    #if os(iOS)
        @MainActor @Test func anExistingSearchBarFollowsLanguageChanges() {
            let window = UIWindow()
            let container = UIView()
            let searchBar = UISearchBar()
            window.addSubview(container)
            container.addSubview(searchBar)
            defer { UIKitLayoutDirection.match(.en, in: [window]) }

            UIKitLayoutDirection.match(.ar, in: [window])
            #expect(searchBar.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            #expect(searchBar.searchTextField.effectiveUserInterfaceLayoutDirection == .rightToLeft)

            UIKitLayoutDirection.match(.en, in: [window])
            #expect(searchBar.effectiveUserInterfaceLayoutDirection == .leftToRight)
            #expect(searchBar.searchTextField.effectiveUserInterfaceLayoutDirection == .leftToRight)
        }
    #endif

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
        #expect(c.textMuted.contrast(with: c.background) >= 4.5, "\(label) textMuted on background")
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

    /// The system face does not scale a fixed size by itself, so it takes Dynamic Type's factor; a bundled face scales
    /// through `relativeTo` and must not take it too (that would scale it twice).
    @Test(arguments: everyTheme, [false, true])
    func theScaleGoesToTheSystemFaceOnly(_ theme: FanousTheme, arabic: Bool) {
        for role in FanousTextRole.allCases {
            let style = role.style(arabic: arabic)
            let family = FanousTypeface.family(arabic ? theme.tokens.font.arabic : theme.tokens.font.latin)
            let doubled = theme.font(role, arabic: arabic, scale: 2)
            let plain = theme.font(role, arabic: arabic)
            if family == nil {
                #expect(doubled == .system(size: style.size * 2, weight: FanousTypeface.weight(style.weight)))
                #expect(plain == .system(size: style.size, weight: FanousTypeface.weight(style.weight)))
            } else {
                #expect(doubled == plain, "\(theme.id) \(role) arabic=\(arabic): a bundled face is not scaled twice")
            }
        }
    }

    /// `fanousPrompt` draws placeholders in `formPlaceholder` on the raised field surface (#107): readable in every theme
    /// and mode.
    @Test(arguments: everyTheme)
    func placeholdersMeetWCAGAAOnTheFieldSurface(_ theme: FanousTheme) {
        let ratio = theme.parts.formPlaceholder.contrast(with: theme.colors.surfaceRaised)
        #expect(ratio >= 4.5, "\(theme.id) dark=\(theme.isDark): \(ratio)")
    }

    @Test(arguments: everyTheme)
    func selectedHeaderNavigationTextMeetsWCAGAA(_ theme: FanousTheme) {
        let parts = theme.parts
        #expect(parts.navActiveText.contrast(with: parts.navBg) >= 4.5)
        #expect(parts.navActiveText.contrast(with: parts.navActiveBg.over(parts.navBg)) >= 4.5)
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
        #expect(DisplayFormat.duration(75, .ar) == "١:١٥")
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

    /// Owner 2026-11-13: Light or Dark only. Until a choice is stored the window follows the device, then keeps it.
    @MainActor @Test func modeIsLightOrDarkAndFirstLaunchAdoptsTheDevice() throws {
        #expect(AppTheme.allCases == [.light, .dark])
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let fresh = AppSettings(defaults: defaults, preferredLanguages: ["en"])
        #expect(!fresh.themeChosen)
        fresh.adoptDeviceScheme(.light)
        #expect(fresh.themeChosen && fresh.theme == .light)
        fresh.adoptDeviceScheme(.dark)
        #expect(fresh.theme == .light)
        #expect(AppSettings(defaults: defaults, preferredLanguages: ["en"]).theme == .light)
    }

    @MainActor @Test func aStoredSystemModeCountsAsNotChosen() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("system", forKey: "AUNTheme")
        let settings = AppSettings(defaults: defaults, preferredLanguages: ["en"])
        #expect(!settings.themeChosen)
        settings.adoptDeviceScheme(.dark)
        #expect(settings.theme == .dark && defaults.string(forKey: "AUNTheme") == "dark")
    }

    /// The app header is the web Fawanees header (apps/web materials.css --m-header, --m-header-edge; nav tokens).
    @Test(arguments: [false, true]) func fawaneesHeaderIsTheWebHeader(_ dark: Bool) {
        let theme = FanousTheme(.fawanees, dark: dark)
        let (end, mid): (UInt32, UInt32) = dark ? (0x0B1D2A, 0x30342D) : (0x0E2B3D, 0x33403D)
        guard case .linear(let angle, _, let stops) = theme.material.header.first else {
            Issue.record("header is not a gradient")
            return
        }
        #expect(angle == 90)
        #expect(stops.map(\.color) == [FanousRGBA(end), FanousRGBA(mid), FanousRGBA(end)])
        #expect(theme.parts.navBg == FanousRGBA(end))
        #expect(theme.parts.navBorder == FanousRGBA(0x184456))
        #expect(theme.parts.navText == FanousRGBA(dark ? 0xF7F1E8 : 0xFBEFD0))
        #expect(theme.parts.navIcon == FanousRGBA(dark ? 0xD6DFE2 : 0xF5CF92))
        #expect(theme.material.headerEdge.map(\.color) == [FanousRGBA(0xF4AE3A, 0.66)])
        #expect(FanousHeader.edgeHeight(theme) == 2)
    }

    /// List dates stay short so they fit their own column: no year in the current year.
    @Test func shortDayDropsTheCurrentYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12)))
        let later = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 12)))
        #expect(DisplayFormat.shortDay(date, .en, now: date, calendar: calendar) == "Nov 6")
        #expect(DisplayFormat.shortDay(date, .en, now: later, calendar: calendar) == "Nov 6, 2026")
        #expect(!DisplayFormat.shortDay(date, .ar, now: date, calendar: calendar).contains("6"))
    }

    /// The light page is the web's cream, with no gold wash over it (the old iPad yellow).
    @Test func fawaneesLightPageIsTheWebBackground() {
        let theme = FanousTheme(.fawanees, dark: false)
        #expect(theme.material.page == [.solid(FanousRGBA(0xF3EEE5))])
    }
}

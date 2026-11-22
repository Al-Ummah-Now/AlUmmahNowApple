import CoreText
import SwiftUI
import os

/// The type roles of the token scale. Arabic uses its own, larger scale with taller lines.
public enum FanousTextRole: Sendable, CaseIterable {
    case display, headline, title, body, label, caption, tvHero, tvBody

    func style(arabic: Bool) -> FanousTypeStyle {
        switch (self, arabic) {
        case (.display, false): FanousScale.Latin.display
        case (.headline, false): FanousScale.Latin.headline
        case (.title, false): FanousScale.Latin.title
        case (.body, false): FanousScale.Latin.body
        case (.label, false): FanousScale.Latin.label
        case (.caption, false): FanousScale.Latin.caption
        case (.tvHero, false): FanousScale.Latin.tvHero
        case (.tvBody, false): FanousScale.Latin.tvBody
        case (.display, true): FanousScale.Arabic.display
        case (.headline, true): FanousScale.Arabic.headline
        case (.title, true): FanousScale.Arabic.title
        case (.body, true): FanousScale.Arabic.body
        case (.label, true): FanousScale.Arabic.label
        case (.caption, true): FanousScale.Arabic.caption
        case (.tvHero, true): FanousScale.Arabic.tvHero
        case (.tvBody, true): FanousScale.Arabic.tvBody
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .display, .tvHero: .largeTitle
        case .headline: .title
        case .title: .title3
        case .body, .tvBody: .body
        case .label: .subheadline
        case .caption: .caption
        }
    }
}

public enum FanousTypeface {
    /// Families bundled with AUNDesign (SIL OFL, texts under Resources/Fonts). Themes on `system-ui` use San Francisco
    /// and the system Arabic face.
    static let bundled: Set<String> = ["Inter", "Noto Kufi Arabic", "Source Serif 4", "Amiri"]

    /// Registers the bundled faces once per process. Safe to call repeatedly.
    public static func register() { _ = registration }

    private static let registration: Void = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }()

    /// The first family in the theme's stack this build can draw, or nil for the system face.
    static func family(_ stack: [String]) -> String? {
        for name in stack {
            if bundled.contains(name) { return name }
            if ["system-ui", "sans-serif", "serif", "-apple-system"].contains(name) { return nil }
        }
        return nil
    }

    /// Space to add between lines so a line is `size × lineHeight` tall, given the face's own line height.
    ///
    /// Every `fanousFont` text asks for this on each body pass, so the answer is computed once per process for each
    /// family and style. Looking a face up by family name through `CTFontCreateWithName` takes CoreText's slow path
    /// and logs a performance note per call, which kept the main thread busy for many seconds at launch.
    static func extraLeading(family: String?, style: FanousTypeStyle) -> CGFloat {
        let key = LeadingKey(family: family, size: style.size, lineHeight: style.lineHeight)
        if let known = leadings.withLock({ $0[key] }) { return known }
        let value = measureLeading(family: family, style: style)
        leadings.withLock { $0[key] = value }
        return value
    }

    /// The lookups `extraLeading` has made so far (tests).
    static var measuredLeadings: Int { leadings.withLock { $0.count } }

    private struct LeadingKey: Hashable {
        let family: String?
        let size: Double
        let lineHeight: Double
    }

    private static let leadings = OSAllocatedUnfairLock<[LeadingKey: CGFloat]>(initialState: [:])

    private static func measureLeading(family: String?, style: FanousTypeStyle) -> CGFloat {
        max(0, style.size * style.lineHeight - naturalLine(family: family, size: style.size))
    }

    /// The face's own line height at `size`: ascent, descent and leading.
    private static func naturalLine(family: String?, size: Double) -> CGFloat {
        register()
        let font: CTFont? =
            family.map {
                let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: $0] as CFDictionary)
                return CTFontCreateWithFontDescriptor(descriptor, size, nil)
            } ?? CTFontCreateUIFontForLanguage(.system, size, nil)
        guard let font else { return size }
        return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    /// How tall one line of `style` in `family` is drawn: the scale's line height, or the face's own when that is taller.
    static func drawnLine(family: String?, style: FanousTypeStyle) -> CGFloat {
        let key = LeadingKey(family: family, size: style.size, lineHeight: style.lineHeight)
        if let known = lines.withLock({ $0[key] }) { return known }
        let value = max(style.size * style.lineHeight, naturalLine(family: family, size: style.size))
        lines.withLock { $0[key] = value }
        return value
    }

    private static let lines = OSAllocatedUnfairLock<[LeadingKey: CGFloat]>(initialState: [:])

    static func weight(_ value: Int) -> Font.Weight {
        switch value {
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        default: .heavy
        }
    }
}

extension FanousTheme {
    /// The font for a role in the theme's typeface, scaled with Dynamic Type.
    public func font(_ role: FanousTextRole, arabic: Bool) -> Font {
        FanousTypeface.register()
        let style = role.style(arabic: arabic)
        let weight = FanousTypeface.weight(style.weight)
        guard let family = FanousTypeface.family(arabic ? tokens.font.arabic : tokens.font.latin) else {
            return .system(size: style.size, weight: weight)
        }
        return .custom(family, size: style.size, relativeTo: role.textStyle).weight(weight)
    }
}

private struct FanousFontModifier: ViewModifier {
    @Environment(\.fanous) private var theme
    @Environment(\.locale) private var locale
    let role: FanousTextRole

    func body(content: Content) -> some View {
        let arabic = locale.language.languageCode == .arabic
        let style = role.style(arabic: arabic)
        let family = FanousTypeface.family(arabic ? theme.tokens.font.arabic : theme.tokens.font.latin)
        content
            .font(theme.font(role, arabic: arabic))
            .tracking(style.letterSpacing)
            .lineSpacing(FanousTypeface.extraLeading(family: family, style: style))
    }
}

extension View {
    /// Text in a token type role, in the site theme's typeface and the language's scale.
    public func fanousFont(_ role: FanousTextRole) -> some View { modifier(FanousFontModifier(role: role)) }
}

extension FanousTheme {
    /// One line of `role` at the default text size: the taller of the theme's Latin and Arabic lines, so a box sized
    /// from it is the same in both languages and fits either script.
    public func lineBox(_ role: FanousTextRole) -> CGFloat {
        let latin = FanousTypeface.drawnLine(family: FanousTypeface.family(tokens.font.latin), style: role.style(arabic: false))
        let arabic = FanousTypeface.drawnLine(
            family: FanousTypeface.family(tokens.font.arabic), style: role.style(arabic: true))
        return max(latin, arabic).rounded(.up)
    }
}

private struct FanousLineBoxModifier: ViewModifier {
    @Environment(\.fanous) private var theme
    /// Dynamic Type's factor for the role, as a percentage of the default size.
    @ScaledMetric private var percent: CGFloat
    let role: FanousTextRole
    let lines: Int
    let alignment: Alignment

    init(role: FanousTextRole, lines: Int, alignment: Alignment) {
        _percent = ScaledMetric(wrappedValue: 100, relativeTo: role.textStyle)
        self.role = role
        self.lines = lines
        self.alignment = alignment
    }

    func body(content: Content) -> some View {
        let height = (theme.lineBox(role) * percent / 100 * CGFloat(lines)).rounded(.up)
        content
            .lineLimit(lines)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: alignment)
    }
}

extension View {
    /// Text in a fixed box of `lines` lines of `role`, the same height in English and Arabic, so the taller Arabic
    /// line can never push what follows further down the page. The box follows the theme's faces and Dynamic Type;
    /// the text is limited to `lines` lines.
    public func fanousLineBox(_ role: FanousTextRole, lines: Int = 1, alignment: Alignment = .topLeading) -> some View {
        modifier(FanousLineBoxModifier(role: role, lines: lines, alignment: alignment))
    }
}

import CoreText
import SwiftUI

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
        content
            .font(theme.font(role, arabic: arabic))
            .tracking(style.letterSpacing)
            .lineSpacing(max(0, style.size * (style.lineHeight - 1.2)))
    }
}

extension View {
    /// Text in a token type role, in the site theme's typeface and the language's scale.
    public func fanousFont(_ role: FanousTextRole) -> some View { modifier(FanousFontModifier(role: role)) }
}

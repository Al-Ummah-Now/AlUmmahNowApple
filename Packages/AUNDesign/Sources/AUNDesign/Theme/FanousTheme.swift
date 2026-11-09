import SwiftUI

/// The theme a window draws with: the site theme an admin set, in the light or dark mode the person chose.
/// Every value comes from the generated registry (`Generated/FanousThemes.swift`), never from literals here.
public struct FanousTheme: Sendable, Equatable {
    public let tokens: FanousThemeTokens
    public let isDark: Bool

    public init(_ id: FanousThemeID, dark: Bool) {
        tokens = id.tokens
        isDark = dark
    }

    public var id: FanousThemeID { tokens.id }
    public var mode: FanousModeTokens { tokens.mode(dark: isDark) }
    public var colors: FanousPalette { mode.colors }
    public var parts: FanousParts { mode.parts }
    public var material: FanousMaterial { mode.material }
    public var player: FanousPlayerTokens { tokens.player }
    public var radius: FanousRadii { tokens.radius }

    public static func == (lhs: FanousTheme, rhs: FanousTheme) -> Bool { lhs.id == rhs.id && lhs.isDark == rhs.isDark }
}

extension EnvironmentValues {
    /// Set once per window by `fanousRoot`; views read it instead of fixed colours.
    @Entry public var fanous = FanousTheme(.fallback, dark: false)
}

extension Color {
    public init(_ value: FanousRGBA) {
        self.init(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
    }
}

extension FanousRGBA {
    /// WCAG 2.1 relative luminance.
    public var luminance: Double {
        func channel(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    public func contrast(with other: FanousRGBA) -> Double {
        let (high, low) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (high + 0.05) / (low + 0.05)
    }

    /// This colour composited over an opaque one, as the screen shows it.
    public func over(_ base: FanousRGBA) -> FanousRGBA {
        let mix = { (top: Double, bottom: Double) in top * alpha + bottom * (1 - alpha) }
        let hex =
            (UInt32((mix(red, base.red) * 255).rounded()) << 16) | (UInt32((mix(green, base.green) * 255).rounded()) << 8)
            | UInt32((mix(blue, base.blue) * 255).rounded())
        return FanousRGBA(hex)
    }
}

/// A semantic colour that resolves against the window's theme, so `Fanous.textPrimary` follows `site.theme`
/// and the colour scheme without any view holding the theme.
public struct FanousRole: ShapeStyle {
    let key: KeyPath<FanousPalette, FanousRGBA> & Sendable
    public func resolve(in environment: EnvironmentValues) -> Color { Color(environment.fanous.colors[keyPath: key]) }
}

/// A component part colour (`--fanous-c-*`) that resolves against the window's theme.
public struct FanousPartRole: ShapeStyle {
    let key: KeyPath<FanousParts, FanousRGBA> & Sendable
    public func resolve(in environment: EnvironmentValues) -> Color { Color(environment.fanous.parts[keyPath: key]) }
}

/// Fanous semantic colours, by the names the web uses.
public enum Fanous {
    public static let background = FanousRole(key: \.background)
    public static let surface = FanousRole(key: \.surface)
    public static let surfaceRaised = FanousRole(key: \.surfaceRaised)
    public static let textPrimary = FanousRole(key: \.textPrimary)
    public static let textSecondary = FanousRole(key: \.textSecondary)
    public static let textMuted = FanousRole(key: \.textMuted)
    public static let link = FanousRole(key: \.link)
    public static let primary = FanousRole(key: \.primary)
    public static let onPrimary = FanousRole(key: \.onPrimary)
    public static let accent = FanousRole(key: \.accent)
    public static let motif = FanousRole(key: \.motif)
    public static let errorText = FanousRole(key: \.errorText)
    public static let successText = FanousRole(key: \.successText)
    public static let live = FanousRole(key: \.live)
    public static let onLive = FanousRole(key: \.onLive)
    public static let outline = FanousRole(key: \.outline)
    public static let divider = FanousRole(key: \.divider)
    public static let focusRing = FanousRole(key: \.focusRing)

    public static func part(_ key: KeyPath<FanousParts, FanousRGBA> & Sendable) -> FanousPartRole { FanousPartRole(key: key) }
}

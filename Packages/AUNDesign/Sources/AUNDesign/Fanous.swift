import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// sRGB color value. Placeholder values from spec §3, replaced by the Epic 10 generated package.
public struct FanousColor: Hashable, Sendable {
    public var hex: UInt32
    public init(_ hex: UInt32) { self.hex = hex }

    var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    var blue: Double { Double(hex & 0xFF) / 255 }

    /// WCAG 2.1 relative luminance.
    var luminance: Double {
        func channel(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(with other: FanousColor) -> Double {
        let (high, low) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (high + 0.05) / (low + 0.05)
    }
}

public struct FanousPalette: Hashable, Sendable {
    public var background, surface, textPrimary, textSecondary, accent, accentText, onAccent, error: FanousColor

    public static let dark = FanousPalette(
        background: FanousColor(0x093041), surface: FanousColor(0x07425A), textPrimary: FanousColor(0xF7F1E8),
        textSecondary: FanousColor(0xC9D6DC), accent: FanousColor(0xFFA037), accentText: FanousColor(0xFFC46B),
        onAccent: FanousColor(0x093041), error: FanousColor(0xFF8A80))

    public static let light = FanousPalette(
        background: FanousColor(0xF7F1E8), surface: FanousColor(0xFFFFFF), textPrimary: FanousColor(0x093041),
        textSecondary: FanousColor(0x4A5C66), accent: FanousColor(0xFFA037), accentText: FanousColor(0x8A4B00),
        onAccent: FanousColor(0x093041), error: FanousColor(0xB00020))
}

/// Fanous semantic colors. They follow the system or forced color scheme.
public enum Fanous {
    public static let background = dynamic(\.background)
    public static let surface = dynamic(\.surface)
    public static let textPrimary = dynamic(\.textPrimary)
    public static let textSecondary = dynamic(\.textSecondary)
    public static let accent = dynamic(\.accent)
    public static let accentText = dynamic(\.accentText)
    public static let onAccent = dynamic(\.onAccent)
    public static let error = dynamic(\.error)

    private static func dynamic(_ key: KeyPath<FanousPalette, FanousColor> & Sendable) -> Color {
        let light = FanousPalette.light[keyPath: key]
        let dark = FanousPalette.dark[keyPath: key]
        #if canImport(UIKit)
            return Color(
                uiColor: UIColor { traits in
                    let value = traits.userInterfaceStyle == .light ? light : dark
                    return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
                })
        #else
            return Color(
                nsColor: NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    let value = isDark ? dark : light
                    return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
                })
        #endif
    }
}

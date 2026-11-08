import AUNCoreBridge
import Foundation
import Observation
import SwiftUI

public enum AppTheme: String, CaseIterable, Sendable {
    case system, dark, light

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

/// User preferences. Launch arguments such as `-AUNLanguage ar` override them, because they land in UserDefaults.
@MainActor @Observable
public final class AppSettings {
    private let defaults: UserDefaults

    public var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: Keys.language) } }
    public var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }

    private enum Keys {
        static let language = "AUNLanguage"
        static let theme = "AUNTheme"
    }

    public init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        language =
            defaults.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:))
            ?? Self.language(from: preferredLanguages)
        theme = defaults.string(forKey: Keys.theme).flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    /// Arabic-first product: Arabic when the device prefers it before English, English otherwise.
    static func language(from preferred: [String]) -> AppLanguage {
        for code in preferred {
            if code.hasPrefix("ar") { return .ar }
            if code.hasPrefix("en") { return .en }
        }
        return .en
    }
}

extension View {
    /// Applies language, direction and theme for a whole window.
    public func fanousRoot(_ settings: AppSettings) -> some View {
        environment(\.l10n, L10n(settings.language))
            .environment(\.locale, settings.language.locale)
            .environment(\.layoutDirection, settings.language.isRTL ? .rightToLeft : .leftToRight)
            .preferredColorScheme(settings.theme.colorScheme)
            .tint(Fanous.accent)
    }
}

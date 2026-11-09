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

/// Resolves the window theme from the site theme and the colour scheme in effect (system or the person's choice).
private struct FanousThemeRoot: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    let siteTheme: SiteThemeStore

    func body(content: Content) -> some View {
        content
            .environment(\.fanous, FanousTheme(siteTheme.id, dark: scheme == .dark))
            .tint(Fanous.link)
            .task { await siteTheme.refresh() }
            .onChange(of: phase) { _, now in
                if now == .active { Task { await siteTheme.refresh() } }
            }
    }
}

extension View {
    /// Applies language, direction, the site theme and the light or dark mode for a whole window.
    public func fanousRoot(_ settings: AppSettings, siteTheme: SiteThemeStore) -> some View {
        modifier(FanousThemeRoot(siteTheme: siteTheme))
            .environment(\.l10n, L10n(settings.language))
            .environment(\.locale, settings.language.locale)
            .environment(\.layoutDirection, settings.language.isRTL ? .rightToLeft : .leftToRight)
            .preferredColorScheme(settings.theme.colorScheme)
    }

    /// The window theme for previews and snapshots, without a store.
    public func fanousTheme(_ id: FanousThemeID, dark: Bool) -> some View {
        environment(\.fanous, FanousTheme(id, dark: dark)).tint(Fanous.link)
    }
}

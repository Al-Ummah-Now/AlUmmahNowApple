import AUNCoreBridge
import Foundation
import Observation
import SwiftUI

/// Light or dark, the person's choice. There is no "System" option (owner, 2026-11-13): until the person picks one,
/// the app follows the device and stores that mode the first time a window appears.
public enum AppTheme: String, CaseIterable, Sendable {
    case light, dark

    public var colorScheme: ColorScheme {
        switch self {
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
    public var theme: AppTheme {
        didSet {
            themeChosen = true
            defaults.set(theme.rawValue, forKey: Keys.theme)
        }
    }
    /// False until a mode is stored: the window then follows the device, and ``adoptDeviceScheme(_:)`` stores it.
    public private(set) var themeChosen: Bool
    /// Opt-in diagnostics & crash reports. Always defaults to `false`.
    public var telemetryEnabled: Bool {
        didSet {
            if telemetryEnabled != oldValue {
                defaults.set(telemetryEnabled, forKey: Keys.telemetryEnabled)
            }
        }
    }

    private enum Keys {
        static let language = "AUNLanguage"
        static let theme = "AUNTheme"
        static let telemetryEnabled = "AUNTelemetryEnabled"
    }

    public init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        language =
            defaults.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:))
            ?? Self.language(from: preferredLanguages)
        // A stored "system" (older builds) or nothing at all both mean "not chosen yet".
        let stored = defaults.string(forKey: Keys.theme).flatMap(AppTheme.init(rawValue:))
        theme = stored ?? .dark
        themeChosen = stored != nil
        telemetryEnabled = defaults.bool(forKey: Keys.telemetryEnabled)
    }

    /// The device's mode at first launch becomes the stored choice, once.
    public func adoptDeviceScheme(_ scheme: ColorScheme) {
        guard !themeChosen else { return }
        theme = scheme == .dark ? .dark : .light
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
    let settings: AppSettings

    func body(content: Content) -> some View {
        let theme = FanousTheme(siteTheme.id, dark: scheme == .dark)
        content
            .environment(\.fanous, theme)
            .onAppear {
                settings.adoptDeviceScheme(scheme)
                applyHeaderText(theme)
            }
            .onChange(of: theme) { _, now in applyHeaderText(now) }
            .tint(Fanous.link)
            .task { await siteTheme.refresh() }
            .onChange(of: phase) { _, now in
                if now == .active { Task { await siteTheme.refresh() } }
            }
    }
}

/// The person's light or dark choice for the window. On iOS it is the window's interface style rather than SwiftUI's
/// `preferredColorScheme`: that preference also decides the status bar style for the whole window and then overrides a
/// screen's own `toolbarColorScheme(.dark, for: .statusBar)`, so the status bar was dark over the navy header in light
/// mode (Apple #87). The window's `overrideUserInterfaceStyle` changes the appearance everywhere in it, sheets and
/// menus included, and leaves the status bar to the screens.
private struct ColorSchemeChoice: ViewModifier {
    let scheme: ColorScheme?

    func body(content: Content) -> some View {
        #if os(iOS)
            content.background(WindowInterfaceStyle(scheme: scheme).allowsHitTesting(false).accessibilityHidden(true))
        #else
            content.preferredColorScheme(scheme)
        #endif
    }
}

#if os(iOS)
    private struct WindowInterfaceStyle: UIViewRepresentable {
        let scheme: ColorScheme?

        func makeUIView(context: Context) -> StyleView {
            let view = StyleView()
            view.scheme = scheme
            return view
        }

        func updateUIView(_ view: StyleView, context: Context) { view.scheme = scheme }

        final class StyleView: UIView {
            var scheme: ColorScheme? {
                didSet { apply() }
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                apply()
            }

            private func apply() {
                let style: UIUserInterfaceStyle =
                    switch scheme {
                    case .dark?: .dark
                    case .light?: .light
                    default: .unspecified
                    }
                if window?.overrideUserInterfaceStyle != style { window?.overrideUserInterfaceStyle = style }
            }
        }
    }
#endif

extension View {
    /// Applies language, direction, the site theme and the light or dark mode for a whole window.
    public func fanousRoot(_ settings: AppSettings, siteTheme: SiteThemeStore) -> some View {
        modifier(FanousThemeRoot(siteTheme: siteTheme, settings: settings))
            .environment(\.l10n, L10n(settings.language))
            .environment(\.locale, settings.language.locale)
            .environment(\.layoutDirection, settings.language.isRTL ? .rightToLeft : .leftToRight)
            .modifier(ColorSchemeChoice(scheme: settings.themeChosen ? settings.theme.colorScheme : nil))
            .modifier(UIKitDirection(language: settings.language))
    }

    /// The window theme for previews and snapshots, without a store.
    public func fanousTheme(_ id: FanousThemeID, dark: Bool) -> some View {
        environment(\.fanous, FanousTheme(id, dark: dark)).tint(Fanous.link)
    }
}

@MainActor private func applyHeaderText(_ theme: FanousTheme) {
    #if os(iOS)
        FanousHeaderText.apply(theme)
    #endif
}

/// Keeps UIKit-presented chrome (menus) in the app language's direction, now and after a language change.
private struct UIKitDirection: ViewModifier {
    let language: AppLanguage

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .onAppear { UIKitLayoutDirection.match(language) }
                .onChange(of: language) { _, now in UIKitLayoutDirection.match(now) }
        #else
            content
        #endif
    }
}

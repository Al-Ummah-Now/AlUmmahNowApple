#if os(macOS)
    import AUNCoreBridge
    import Foundation

    /// The Mac window chrome (traffic lights, title bar, toolbar) follows the app's language, not the system's.
    ///
    /// SwiftUI's `layoutDirection` mirrors only the content. With AppKit left-to-right under a right-to-left
    /// split view, the window toolbar loses its items (no channel switcher, no account button) in Arabic.
    /// AppKit reads its direction once, at launch, so this runs before the first window; a language change
    /// in the app mirrors the chrome on the next launch.
    public enum AppKitLayoutDirection {
        public static func match(_ language: AppLanguage, defaults: UserDefaults = .standard) {
            var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AppleTextDirection"] = language.isRTL
            arguments["NSForceRightToLeftWritingDirection"] = language.isRTL
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
    }
#endif

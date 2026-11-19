#if os(iOS)
    import AUNCoreBridge
    import UIKit

    /// UIKit-drawn chrome (menus, the identity menu's rows and check marks, context menus) follows the app's
    /// language, not the system's. SwiftUI's `layoutDirection` mirrors only SwiftUI content; a `Menu` is presented by
    /// UIKit and read its direction from the system language, so in-app Arabic showed left-to-right menus.
    public enum UIKitLayoutDirection {
        @MainActor public static func match(_ language: AppLanguage) {
            UIView.appearance().semanticContentAttribute = language.isRTL ? .forceRightToLeft : .forceLeftToRight
        }
    }
#endif

#if os(iOS)
    import SwiftUI

    /// The navigation bar's own titles (inline and large) in the web header's text colour (`navText`), so the system
    /// title on the header matches the web header exactly. Applied per theme and mode by `fanousRoot`.
    public enum FanousHeaderText {
        @MainActor public static func apply(_ theme: FanousTheme) {
            let color = UIColor(Color(theme.parts.navText))
            let bar = UINavigationBar.appearance()
            bar.titleTextAttributes = [.foregroundColor: color]
            bar.largeTitleTextAttributes = [.foregroundColor: color]
        }
    }
#endif

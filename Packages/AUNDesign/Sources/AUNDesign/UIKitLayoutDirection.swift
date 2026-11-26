#if os(iOS)
    import AUNCoreBridge
    import UIKit

    /// UIKit-drawn chrome (menus, the identity menu's rows and check marks, context menus) follows the app's
    /// language, not the system's. SwiftUI's `layoutDirection` mirrors only SwiftUI content; a `Menu` is presented by
    /// UIKit and read its direction from the system language, so in-app Arabic showed left-to-right menus.
    @MainActor public enum UIKitLayoutDirection {
        public static func match(_ language: AppLanguage) {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
            match(language, in: windows)
        }

        static func match(_ language: AppLanguage, in windows: [UIWindow]) {
            let direction: UISemanticContentAttribute = language.isRTL ? .forceRightToLeft : .forceLeftToRight
            UIView.appearance().semanticContentAttribute = direction
            UISearchBar.appearance().semanticContentAttribute = direction
            UISearchTextField.appearance().semanticContentAttribute = direction

            // Appearance changes apply when views enter a window. Update search bars already on screen too.
            for window in windows {
                updateSearchBars(in: window, direction: direction)
            }
        }

        private static func updateSearchBars(in view: UIView, direction: UISemanticContentAttribute) {
            if let searchBar = view as? UISearchBar {
                searchBar.semanticContentAttribute = direction
                let field = searchBar.searchTextField
                field.semanticContentAttribute = direction
                // UITextField already mirrors its leading overlay. UIKit can put the RTL
                // magnifier in the trailing overlay, where it is hidden.
                if direction == .forceRightToLeft, field.leftView == nil, let icon = field.rightView as? UIImageView {
                    field.rightView = nil
                    field.leftView = icon
                    field.leftViewMode = .always
                }
                searchBar.setNeedsLayout()
                field.setNeedsLayout()
                return
            }
            for subview in view.subviews {
                updateSearchBars(in: subview, direction: direction)
            }
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

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

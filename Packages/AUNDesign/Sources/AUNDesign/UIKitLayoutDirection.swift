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

#if os(iOS)
    import SwiftUI

    extension View {
        /// The system search field on the header (`.searchable`) with the web header's search colours: the
        /// placeholder in `navSearchPlaceholder` and typed text in `navSearchText`. The system placeholder read about
        /// 3.2:1 on the field; the token reads at least 4.5:1 in every theme. Put it on the view that is `.searchable`.
        public func fanousSearchField() -> some View { background(FanousSearchFieldStyler()) }
    }

    /// UIKit draws the search field and has no placeholder colour to set ahead of time: setting `placeholder` (as
    /// SwiftUI does for the prompt) resets it. So, once the field is on screen and again whenever the view updates
    /// (a language or theme change), the field's placeholder is re-set with the token colour.
    private struct FanousSearchFieldStyler: UIViewRepresentable {
        @Environment(\.fanous) private var theme
        @Environment(\.l10n) private var l10n

        func makeUIView(context: Context) -> StylerView { StylerView() }

        func updateUIView(_ view: StylerView, context: Context) {
            view.colors = (UIColor(Color(theme.parts.navSearchPlaceholder)), UIColor(Color(theme.parts.navSearchText)))
            // A new language re-sets the prompt, and with it the system colour.
            view.language = l10n.language
            view.restyleSoon()
        }

        final class StylerView: UIView {
            var colors: (placeholder: UIColor, text: UIColor)?
            var language: AppLanguage?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                restyleSoon()
            }

            /// The search field joins the bar after the content appears, so the pass repeats briefly.
            func restyleSoon() {
                for delay in [0.0, 0.3, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restyle() }
                }
            }

            private func restyle() {
                guard let window, let colors else { return }
                for field in Self.searchFields(in: window) {
                    let prompt = field.attributedPlaceholder?.string ?? field.placeholder ?? ""
                    let current = field.attributedPlaceholder?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                    if !prompt.isEmpty, (current as? UIColor) != colors.placeholder {
                        field.attributedPlaceholder = NSAttributedString(
                            string: prompt, attributes: [.foregroundColor: colors.placeholder])
                    }
                    field.textColor = colors.text
                }
            }

            private static func searchFields(in view: UIView) -> [UISearchTextField] {
                if let field = view as? UISearchTextField { return [field] }
                return view.subviews.flatMap { searchFields(in: $0) }
            }
        }
    }
#endif

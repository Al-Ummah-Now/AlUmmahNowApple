import SwiftUI

/// The web header (`.aun-header` in `packages/fanous-tokens/nav/aun-nav.css` with the theme's `--m-header` and
/// `--m-header-edge`), so every app bar has the web header's colours, mode for mode. Everything comes from the
/// generated registry: the `header` material, the `headerEdge` shadows and the `nav*` parts. Dark in every mode.
public enum FanousHeader {
    /// The header fill as a `ShapeStyle`, for bars that take a style (navigation bar, window toolbar).
    public static func style(_ theme: FanousTheme) -> AnyShapeStyle {
        let fills = theme.material.header
        guard let top = fills.first else { return AnyShapeStyle(Color(theme.parts.navBg)) }
        switch top {
        case .solid(let color):
            return AnyShapeStyle(Color(color))
        case .linear(let angle, _, let stops):
            let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
            let (start, end) = FanousPaint.linearPoints(angle: angle, in: unit)
            return AnyShapeStyle(
                LinearGradient(
                    gradient: FanousPaint.gradient(stops), startPoint: UnitPoint(x: start.x, y: start.y),
                    endPoint: UnitPoint(x: end.x, y: end.y)))
        case .radial:
            return AnyShapeStyle(Color(theme.parts.navBg))
        }
    }

    /// Height of the edge under the bar: the 1px border plus whatever the theme's header edge casts below it.
    public static func edgeHeight(_ theme: FanousTheme) -> CGFloat { 1 + FanousPaint.bleed(theme.material.headerEdge) }
}

/// The header surface as a view: the `header` material, for custom bars (Mac sidebar head, TV, mockups).
public struct FanousHeaderSurface: View {
    @Environment(\.fanous) private var theme

    public init() {}

    public var body: some View {
        FanousSurface(fills: theme.material.header, shape: .rect)
    }
}

/// The header's bottom edge, drawn under the bar: the `navBorder` line, then the theme's header edge (Fawanees: a 1px
/// gold rule at 66%). A navigation bar clips its own background, so the edge sits just below it instead of inside.
public struct FanousHeaderEdge: View {
    @Environment(\.fanous) private var theme

    public init() {}

    public var body: some View {
        let edge = theme.material.headerEdge
        VStack(spacing: 0) {
            Rectangle().fill(Color(theme.parts.navBorder)).frame(height: 1)
            Canvas { context, size in
                let bar = CGRect(x: 0, y: -400, width: size.width, height: 400)
                FanousPaint.outerShadows(edge, shape: .rect, rect: bar, in: context)
            }
            .frame(height: FanousPaint.bleed(edge))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A control on the header, as the web draws it (`.aun-icon-btn`, `.aun-lang`, `.upload-action`): an outlined pill in
/// `navSearchBorder`, `navText` label, `navIcon` icons, `navHover` when pressed. `.plain` drops the outline, as the
/// account button does.
public struct FanousHeaderButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case pill, icon, plain }
    private let kind: Kind

    public init(_ kind: Kind = .pill) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        FanousHeaderButtonBody(kind: kind, configuration: configuration)
    }
}

private struct FanousHeaderButtonBody: View {
    @Environment(\.fanous) private var theme
    @Environment(\.isEnabled) private var enabled
    let kind: FanousHeaderButtonStyle.Kind
    let configuration: ButtonStyleConfiguration

    var body: some View {
        let parts = theme.parts
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .labelStyle(FanousHeaderLabelStyle(icon: Color(parts.navIcon)))
            .foregroundStyle(Color(parts.navText))
            .padding(.horizontal, kind == .pill ? 12 : 0)
            .frame(minWidth: 40, minHeight: 40)
            .background {
                if configuration.isPressed { Capsule().fill(Color(parts.navHover)) }
            }
            .overlay {
                if kind != .plain { Capsule().strokeBorder(Color(parts.navSearchBorder), lineWidth: 1) }
            }
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.6)
    }
}

/// Icon in `navIcon`, title in the label's colour, as on the web header.
private struct FanousHeaderLabelStyle: LabelStyle {
    let icon: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 17, weight: .medium)).foregroundStyle(icon)
            configuration.title
        }
    }
}

/// A screen title on the header, in `navText`.
public struct FanousHeaderTitle: View {
    @Environment(\.fanous) private var theme
    private let text: String
    private let large: Bool

    public init(_ text: String, large: Bool = false) {
        self.text = text
        self.large = large
    }

    public var body: some View {
        Text(text)
            .font(large ? .system(size: 28, weight: .bold) : .headline)
            .foregroundStyle(Color(theme.parts.navText))
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct FanousHeaderBar: ViewModifier {
    @Environment(\.fanous) private var theme
    let title: String?

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .toolbarBackground(FanousHeader.style(theme), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    if let title { ToolbarItem(placement: .principal) { FanousHeaderTitle(title) } }
                }
                .safeAreaInset(edge: .top, spacing: 0) { FanousHeaderEdge() }
        #elseif os(macOS)
            content
                .toolbarBackground(FanousHeader.style(theme), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
                .toolbarColorScheme(.dark, for: .windowToolbar)
                .background(DarkTitlebar().frame(width: 0, height: 0))
                .safeAreaInset(edge: .top, spacing: 0) { FanousHeaderEdge() }
        #else
            content.safeAreaInset(edge: .top, spacing: 0) { FanousHeaderEdge() }
        #endif
    }
}

#if os(macOS)
    /// The header is dark in every mode, so the title bar takes the dark appearance: `toolbarColorScheme` only reaches the
    /// toolbar's text, and in light mode the glass behind the title, the sidebar button and menus stayed white.
    private struct DarkTitlebar: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { Probe() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        final class Probe: NSView {
            private var observer: NSObjectProtocol?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                // Leaving the window (also on the way out) stops the observation.
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
                guard let window else { return }
                Self.apply(to: window)
                // The title bar is rebuilt when the toolbar changes (Studio's split view mounts after sign-in) and the
                // chosen colour scheme resets appearances, so keep asserting it; it only writes when it differs.
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didUpdateNotification, object: window, queue: .main
                ) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window { Probe.apply(to: window) }
                    }
                }
            }

            // The close button sits in the title bar view, which also holds the toolbar items.
            @MainActor static func apply(to window: NSWindow) {
                guard let bar = window.standardWindowButton(.closeButton)?.superview else { return }
                if bar.appearance?.name != .darkAqua { bar.appearance = NSAppearance(named: .darkAqua) }
            }
        }
    }
#endif

extension View {
    /// Puts the web header on this screen's bar: the header gradient behind the bar and the status bar, light bar
    /// content, the border and gold rule under it. `title` draws the screen title in `navText` (the system title
    /// would be plain white).
    public func fanousHeaderBar(title: String? = nil) -> some View { modifier(FanousHeaderBar(title: title)) }
}

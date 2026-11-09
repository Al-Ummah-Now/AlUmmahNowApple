import AUNCoreBridge
import SwiftUI

/// Remote thumbnail in the theme's large radius with the web's hairline ring; `lifted` adds the focus and press edge.
public struct ThumbnailImage: View {
    @Environment(\.fanous) private var theme
    private let url: URL?
    private let lifted: Bool

    public init(url: URL?, lifted: Bool = false) {
        self.url = url
        self.lifted = lifted
    }

    public var body: some View {
        let shape = FanousShape.rounded(theme.radius.lg)
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(Fanous.surfaceRaised)
            .overlay { FanousMotif(.loader).frame(width: 40, height: 40).opacity(0.35) }
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFill() }
                    }
                }
            }
            .clipShape(shape)
            .overlay { shape.stroke(Color(theme.colors.divider).opacity(0.6), lineWidth: 1) }
            .background { FanousSurface(fills: [], shadows: lifted ? theme.material.thumbEdge : [], shape: shape) }
    }
}

/// The duration badge on a thumbnail.
public struct DurationBadge: View {
    @Environment(\.fanous) private var theme
    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(Fanous.part(\.badgeDurationText))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Fanous.part(\.badgeDurationBg), in: FanousShape.rounded(theme.radius.sm))
            .environment(\.layoutDirection, .leftToRight)
    }
}

/// Button kinds of the web (`.b-primary`, `.b-secondary`, `.b-ghost`), with their materials and pressed states.
public struct FanousButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, ghost }
    private let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        FanousButtonBody(kind: kind, configuration: configuration)
    }
}

private struct FanousButtonBody: View {
    @Environment(\.fanous) private var theme
    @Environment(\.isEnabled) private var enabled
    let kind: FanousButtonStyle.Kind
    let configuration: ButtonStyleConfiguration

    var body: some View {
        let pressed = configuration.isPressed
        let shape = FanousShape.rounded(theme.radius.pill)
        let parts = theme.parts
        configuration.label
            .fanousFont(.label)
            .fontWeight(.semibold)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color(text(parts)))
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background { surface(shape, pressed: pressed) }
            .overlay { shape.strokeBorder(Color(border(parts)), lineWidth: kind == .ghost ? 0 : 1) }
            .contentShape(shape)
            .offset(y: pressed && kind == .primary ? 1 : 0)
            .opacity(enabled ? 1 : 0.55)
            .animation(.easeOut(duration: FanousScale.durationFast), value: pressed)
    }

    @ViewBuilder private func surface(_ shape: FanousShape, pressed: Bool) -> some View {
        switch kind {
        case .primary: FanousSurfaceKind(kind: pressed ? .primaryPress : .primary, shape: shape)
        case .secondary: FanousSurfaceKind(kind: pressed ? .hover : .card, shape: shape, borderless: true)
        case .ghost: if pressed { FanousSurfaceKind(kind: .hover, shape: shape) }
        }
    }

    private func text(_ parts: FanousParts) -> FanousRGBA {
        switch kind {
        case .primary: parts.buttonPrimaryText
        case .secondary: parts.buttonSecondaryText
        case .ghost: parts.buttonGhostText
        }
    }

    private func border(_ parts: FanousParts) -> FanousRGBA {
        switch kind {
        case .primary: parts.buttonPrimaryBorder
        case .secondary: parts.buttonSecondaryBorder
        case .ghost: parts.buttonGhostBorder
        }
    }
}

/// A circular icon button (`.b` icon form): ghost at rest, the hover material when pressed.
public struct FanousIconButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Fanous.part(\.buttonIconText))
            .frame(width: 44, height: 44)
            .background { if configuration.isPressed { FanousSurfaceKind(kind: .hover, shape: .circle) } }
            .contentShape(Circle())
    }
}

/// A material from the window's theme, as a view.
public struct FanousSurfaceKind: View {
    @Environment(\.fanous) private var theme
    let kind: FanousMaterialKind
    let shape: FanousShape
    var borderless = false

    public init(kind: FanousMaterialKind, shape: FanousShape, borderless: Bool = false) {
        self.kind = kind
        self.shape = shape
        self.borderless = borderless
    }

    public var body: some View {
        let recipe = kind.recipe(theme)
        FanousSurface(
            fills: recipe.fills, border: borderless ? [] : recipe.border, shadows: recipe.shadows, shape: shape,
            blur: kind.blurs ? theme.tokens.blur : nil)
    }
}

/// The theme's motif, resolved for the mode: the loader lantern, the page pattern or the sign-in header.
public struct FanousMotif: View {
    public enum Asset: String, Sendable { case loader, pattern, authHeader }
    @Environment(\.fanous) private var theme
    private let asset: Asset

    public init(_ asset: Asset) { self.asset = asset }

    public static func name(_ asset: Asset, theme: FanousTheme) -> String {
        "fanous-\(theme.id.rawValue)-\(asset.rawValue)-\(theme.isDark ? "dark" : "light")"
    }

    public static func exists(_ asset: Asset, theme: FanousTheme) -> Bool {
        #if canImport(UIKit)
            UIImage(named: name(asset, theme: theme), in: .module, with: nil) != nil
        #else
            Bundle.module.image(forResource: name(asset, theme: theme)) != nil
        #endif
    }

    public var body: some View {
        Image(Self.name(asset, theme: theme), bundle: .module).resizable().scaledToFit().accessibilityHidden(true)
    }
}

/// The theme loader: its lantern, breathing in the theme's glow. Still when Reduce Motion is on.
public struct ThemeLoader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.l10n) private var l10n
    @State private var lit = false

    public init() {}

    public var body: some View {
        VStack(spacing: 14) {
            FanousMotif(.loader)
                .frame(width: 56, height: 56)
                .opacity(lit ? 1 : 0.55)
                .scaleEffect(lit ? 1 : 0.94)
            Text(l10n("common.loading")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else { lit = true; return }
            withAnimation(.easeInOut(duration: FanousScale.durationGlowPulse / 2).repeatForever(autoreverses: true)) {
                lit = true
            }
        }
    }
}

/// A skeleton block with the web's sweeping shine, which runs in the reading direction.
public struct SkeletonBlock: View {
    @Environment(\.fanous) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1
    private let radius: KeyPath<FanousRadii, Double>

    public init(radius: KeyPath<FanousRadii, Double> = \.md) { self.radius = radius }

    public var body: some View {
        let shape = FanousShape.rounded(theme.radius[keyPath: radius])
        shape.fill(Color(theme.parts.skeletonBg))
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color(theme.parts.skeletonShine), .clear], startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width)
                        .offset(x: phase * proxy.size.width)
                    }
                    .clipShape(shape)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: FanousScale.durationGlowPulse).repeatForever(autoreverses: false)) { phase = 1 }
            }
            .accessibilityHidden(true)
    }
}

/// An empty state: the theme's motif, a title and a line of help.
public struct EmptyStateView: View {
    private let title: String
    private let message: String?

    public init(title: String, message: String? = nil) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 8) {
            FanousMotif(.loader).frame(width: 44, height: 44).opacity(0.8).padding(.bottom, 4)
            Text(title).fanousFont(.title).foregroundStyle(Fanous.part(\.emptyTitle))
            if let message { Text(message).fanousFont(.body).foregroundStyle(Fanous.part(\.emptyBody)) }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, FanousScale.spacingXxxl)
        .padding(.horizontal, FanousScale.spacingXl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-area error with a retry action, on a raised card.
public struct ErrorStateView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.fanous) private var theme
    private let retry: () -> Void

    public init(retry: @escaping () -> Void) { self.retry = retry }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Fanous.errorText)
                .accessibilityHidden(true)
            Text(l10n("common.error.load")).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                .multilineTextAlignment(.center)
            Button(l10n("common.retry"), action: retry).buttonStyle(FanousButtonStyle(.primary))
                .accessibilityIdentifier("retry")
        }
        .padding(FanousScale.spacingXl)
        .frame(maxWidth: 420)
        .fanousMaterial(.raised) { .rounded($0.xl) }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// The page wash behind a whole screen, under the safe areas.
    public func fanousPage() -> some View { modifier(FanousPageBackground()) }
}

private struct FanousPageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background { FanousSurfaceKind(kind: .page, shape: .rect).ignoresSafeArea() }
    }
}

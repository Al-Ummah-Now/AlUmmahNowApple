import SwiftUI

/// The outline a material is drawn in. Spread rings and glows grow it, as CSS grows a border box.
public enum FanousShape: Shape, Equatable {
    case rect
    case rounded(Double)
    case capsule
    case circle

    public func path(in rect: CGRect) -> Path { path(in: rect, expand: 0) }

    public func path(in rect: CGRect, expand: Double) -> Path {
        let box = rect.insetBy(dx: -expand, dy: -expand)
        guard box.width > 0, box.height > 0 else { return Path() }
        switch self {
        case .rect: return Path(box)
        case .rounded(let radius):
            let corner = min(max(0, radius + expand), min(box.width, box.height) / 2)
            return Path(roundedRect: box, cornerRadius: corner, style: .circular)
        case .capsule: return Path(roundedRect: box, cornerRadius: min(box.width, box.height) / 2, style: .circular)
        case .circle: return Path(ellipseIn: box)
        }
    }
}

/// Paints the generated CSS layers natively: the same gradient geometry, layer order and shadow model as the web.
public enum FanousPaint {
    /// The CSS gradient line for an angle (0 up, 90 to the right), through the centre and long enough to reach the corners.
    public static func linearPoints(angle degrees: Double, in rect: CGRect) -> (start: CGPoint, end: CGPoint) {
        let theta = degrees * .pi / 180
        let (dx, dy) = (sin(theta), -cos(theta))
        let half = (abs(rect.width * dx) + abs(rect.height * dy)) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = CGPoint(x: center.x - dx * half, y: center.y - dy * half)
        return (start, CGPoint(x: center.x + dx * half, y: center.y + dy * half))
    }

    /// Radii of a radial gradient around `center` in `rect`, following the CSS extent keywords.
    public static func radialRadii(circle: Bool, extent: FanousExtent, center: CGPoint, in rect: CGRect) -> (CGFloat, CGFloat) {
        let xs = [center.x - rect.minX, rect.maxX - center.x].map(abs)
        let ys = [center.y - rect.minY, rect.maxY - center.y].map(abs)
        let (nearX, farX, nearY, farY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        switch extent {
        case .radii(let fx, let fy):
            let rx = rect.width * fx
            return (rx, circle ? rx : rect.height * fy)
        case .closestSide: return circle ? (min(nearX, nearY), min(nearX, nearY)) : (nearX, nearY)
        case .farthestSide: return circle ? (max(farX, farY), max(farX, farY)) : (farX, farY)
        case .closestCorner:
            if circle { let r = hypot(nearX, nearY); return (r, r) }
            return (nearX * 2.squareRoot(), nearY * 2.squareRoot())
        case .farthestCorner:
            if circle { let r = hypot(farX, farY); return (r, r) }
            return (farX * 2.squareRoot(), farY * 2.squareRoot())
        }
    }

    static func gradient(_ stops: [FanousStop]) -> Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: Color($0.color), location: $0.location) })
    }

    /// Draws background layers into `path`. CSS lists the top layer first, so they are painted in reverse.
    public static func fill(_ fills: [FanousFill], path: Path, rect: CGRect, rtl: Bool, in context: GraphicsContext) {
        for fill in fills.reversed() {
            switch fill {
            case .solid(let color):
                context.fill(path, with: .color(Color(color)))
            case .linear(let angle, let logical, let stops):
                let (start, end) = linearPoints(angle: logical && rtl ? -angle : angle, in: rect)
                context.fill(path, with: .linearGradient(gradient(stops), startPoint: start, endPoint: end))
            case .radial(let circle, let extent, let unit, let logicalX, let stops):
                let center = CGPoint(
                    x: rect.minX + rect.width * (logicalX && rtl ? 1 - unit.x : unit.x), y: rect.minY + rect.height * unit.y)
                let (rx, ry) = radialRadii(circle: circle, extent: extent, center: center, in: rect)
                guard rx > 0.01, ry > 0.01 else { continue }
                var layer = context
                layer.clip(to: path)
                layer.translateBy(x: center.x, y: center.y)
                layer.scaleBy(x: 1, y: ry / rx)
                let cover = rect.offsetBy(dx: -center.x, dy: -center.y)
                let scaled = CGRect(x: cover.minX, y: cover.minY * rx / ry, width: cover.width, height: cover.height * rx / ry)
                layer.fill(
                    Path(scaled.insetBy(dx: -1, dy: -1)),
                    with: .radialGradient(gradient(stops), center: .zero, startRadius: 0, endRadius: rx))
            }
        }
    }

    /// Outer shadows: rings (spread) and glows (blur), kept outside the box as CSS keeps them.
    public static func outerShadows(_ shadows: [FanousBoxShadow], shape: FanousShape, rect: CGRect, in context: GraphicsContext) {
        for shadow in shadows.reversed() where !shadow.inset {
            var layer = context
            var outside = Path(rect.insetBy(dx: -4096, dy: -4096))
            outside.addPath(shape.path(in: rect))
            layer.clip(to: outside, style: FillStyle(eoFill: true))
            if shadow.blur > 0 { layer.addFilter(.blur(radius: shadow.blur / 2)) }
            let cast = shape.path(in: rect.offsetBy(dx: shadow.x, dy: shadow.y), expand: shadow.spread)
            layer.fill(cast, with: .color(Color(shadow.color)))
        }
    }

    /// Inset shadows: top sheens, inner lines and inner glows, clipped to the box.
    public static func insetShadows(_ shadows: [FanousBoxShadow], shape: FanousShape, rect: CGRect, in context: GraphicsContext) {
        for shadow in shadows.reversed() where shadow.inset {
            var layer = context
            layer.clip(to: shape.path(in: rect))
            if shadow.blur > 0 { layer.addFilter(.blur(radius: shadow.blur / 2)) }
            var ring = Path(rect.insetBy(dx: -rect.width - 64, dy: -rect.height - 64))
            ring.addPath(shape.path(in: rect.offsetBy(dx: shadow.x, dy: shadow.y), expand: -shadow.spread))
            layer.fill(ring, with: .color(Color(shadow.color)), style: FillStyle(eoFill: true))
        }
    }

    /// How far outer shadows reach beyond the box, so the canvas can grow to hold them.
    public static func bleed(_ shadows: [FanousBoxShadow]) -> CGFloat {
        shadows.filter { !$0.inset }.map { max(abs($0.x), abs($0.y)) + $0.blur + max(0, $0.spread) }.max() ?? 0
    }
}

/// A themed surface: fill layers, an optional 1px gradient border, outer and inset shadows, and the backdrop blur
/// of glass themes. The same recipe as the web's `background: fill padding-box, border border-box; box-shadow: edge`.
public struct FanousSurface: View {
    public var fills: [FanousFill]
    public var border: [FanousFill]
    public var shadows: [FanousBoxShadow]
    public var shape: FanousShape
    public var blur: FanousBlur?
    @Environment(\.layoutDirection) private var direction

    public init(
        fills: [FanousFill], border: [FanousFill] = [], shadows: [FanousBoxShadow] = [], shape: FanousShape,
        blur: FanousBlur? = nil
    ) {
        self.fills = fills
        self.border = border
        self.shadows = shadows
        self.shape = shape
        self.blur = blur
    }

    public var body: some View {
        let bleed = FanousPaint.bleed(shadows)
        let rtl = direction == .rightToLeft
        ZStack {
            if blur != nil { shape.fill(.ultraThinMaterial) }
            Canvas { context, size in
                let rect = CGRect(x: bleed, y: bleed, width: size.width - 2 * bleed, height: size.height - 2 * bleed)
                guard rect.width > 0, rect.height > 0 else { return }
                FanousPaint.outerShadows(shadows, shape: shape, rect: rect, in: context)
                let inner = border.isEmpty ? shape.path(in: rect) : shape.path(in: rect, expand: -1)
                FanousPaint.fill(fills, path: inner, rect: rect, rtl: rtl, in: context)
                if !border.isEmpty {
                    var ring = shape.path(in: rect)
                    ring.addPath(inner)
                    var edge = context
                    edge.clip(to: ring, style: FillStyle(eoFill: true))
                    FanousPaint.fill(border, path: shape.path(in: rect), rect: rect, rtl: rtl, in: edge)
                }
                FanousPaint.insetShadows(shadows, shape: shape, rect: rect, in: context)
            }
            .padding(-bleed)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The materials of the web's material system, by the names it uses (`--m-*`).
public enum FanousMaterialKind: Sendable, CaseIterable {
    case page, header, rail, card, raised, control, hero, primary, primaryHover, primaryPress, active, hover, selected

    /// Fill, border and shadow for this material in a theme, paired as the web pairs them.
    public func recipe(_ theme: FanousTheme) -> (fills: [FanousFill], border: [FanousFill], shadows: [FanousBoxShadow]) {
        let m = theme.material
        switch self {
        case .page: return (m.page, [], [])
        case .header: return (m.header, [], m.headerEdge)
        case .rail: return (m.rail, [], m.railEdge)
        case .card: return (m.card, m.border, m.cardEdge)
        case .raised: return (m.raised, [], m.raisedEdge)
        case .control: return (m.control, [], m.controlEdge)
        case .hero: return (m.hero, m.border, m.cardEdge)
        case .primary: return (m.primary, [], m.primaryEdge)
        case .primaryHover: return (m.primaryHover, [], m.primaryEdge)
        case .primaryPress: return (m.primaryPress, [], m.primaryEdge)
        case .active: return (m.active, [], m.activeEdge)
        case .hover: return (m.hover, [], [])
        case .selected: return (m.sel, [], m.selEdge + m.selGlow)
        }
    }

    /// Glass themes blur what is behind their translucent chrome.
    var blurs: Bool { [.header, .rail, .raised].contains(self) }
}

private struct FanousMaterialBackground: ViewModifier {
    @Environment(\.fanous) private var theme
    let kind: FanousMaterialKind
    let shape: (FanousRadii) -> FanousShape

    func body(content: Content) -> some View {
        let recipe = kind.recipe(theme)
        content.background {
            FanousSurface(
                fills: recipe.fills, border: recipe.border, shadows: recipe.shadows, shape: shape(theme.radius),
                blur: kind.blurs ? theme.tokens.blur : nil)
        }
    }
}

extension View {
    /// Draws a web material behind the view, in the window's site theme. The radius comes from the theme's own scale.
    public func fanousMaterial(_ kind: FanousMaterialKind, shape: @escaping (FanousRadii) -> FanousShape) -> some View {
        modifier(FanousMaterialBackground(kind: kind, shape: shape))
    }

    /// Draws a web material behind the view with a fixed outline.
    public func fanousMaterial(_ kind: FanousMaterialKind, _ shape: FanousShape = .rect) -> some View {
        modifier(FanousMaterialBackground(kind: kind, shape: { _ in shape }))
    }

    /// Draws arbitrary generated layers behind the view, for player chrome and one-off parts.
    public func fanousLayers(
        _ fills: [FanousFill], border: [FanousFill] = [], shadows: [FanousBoxShadow] = [], shape: FanousShape,
        blur: FanousBlur? = nil
    ) -> some View {
        background { FanousSurface(fills: fills, border: border, shadows: shadows, shape: shape, blur: blur) }
    }
}

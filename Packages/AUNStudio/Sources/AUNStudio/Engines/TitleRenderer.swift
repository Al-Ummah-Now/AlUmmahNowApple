import AUNCoreBridge
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Draws one title over a transparent frame with CoreText, so Arabic shapes and runs right to left inside the title.
/// The editor's preview and the export use the same images, so what the creator sees is what is rendered.
public enum TitleRenderer {
    /// Where the title's box sits on a frame of `canvas` (top-left origin), for tests and hit areas.
    public struct Layout: Equatable, Sendable {
        public var box: CGRect
        public var rightToLeft: Bool
    }

    /// A transparent `canvas`-sized image with the title drawn on it.
    public static func image(_ title: FlattenedTimeline.Title, brand: TitleBrand, canvas: CGSize) -> CGImage? {
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(title, brand: brand, canvas: CGSize(width: width, height: height), in: context)
        return context.makeImage()
    }

    /// The title's box on the frame (top-left origin), or nil when it has no text.
    public static func layout(_ title: FlattenedTimeline.Title, brand: TitleBrand, canvas: CGSize) -> Layout? {
        Prepared(title, brand: brand, canvas: canvas).map { Layout(box: $0.box, rightToLeft: $0.rightToLeft) }
    }

    static func draw(_ title: FlattenedTimeline.Title, brand: TitleBrand, canvas: CGSize, in context: CGContext) {
        guard let prepared = Prepared(title, brand: brand, canvas: canvas) else { return }
        prepared.draw(in: context)
    }

    // MARK: Fonts and colours

    static func font(_ family: String, size: CGFloat, bold: Bool) -> CTFont {
        if family != TitleBrand.systemFont {
            let named = CTFontCreateWithName(family as CFString, size, nil)
            if (CTFontCopyFamilyName(named) as String).caseInsensitiveCompare(family) == .orderedSame {
                return bold ? CTFontCreateCopyWithSymbolicTraits(named, size, nil, .traitBold, .traitBold) ?? named : named
            }
        }
        return CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    static func color(_ hex: String?, alpha: CGFloat = 1) -> CGColor? {
        guard let hex, let rgb = TitleBrand.rgb(hex) else { return nil }
        return CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    static func isRightToLeft(_ locale: String) -> Bool {
        Locale.Language(identifier: locale).characterDirection == .rightToLeft
    }

    static func logoImage(_ data: Data?) -> CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Everything measured once: lines, box and logo, in top-left coordinates.
    struct Prepared {
        struct Line {
            let line: CTLine
            let width: CGFloat
            let ascent: CGFloat
            let descent: CGFloat
            let rightToLeft: Bool
        }

        let lines: [Line]
        let box: CGRect
        let padding: CGSize
        let logo: CGImage?
        let logoSide: CGFloat
        let logoSpace: CGFloat
        let rightToLeft: Bool
        let style: FlattenedTimeline.TitleStyle
        let brand: TitleBrand
        let canvas: CGSize
        let scale: CGFloat
        let lineGap: CGFloat

        init?(_ title: FlattenedTimeline.Title, brand: TitleBrand, canvas: CGSize) {
            let texts = title.lines
            guard !texts.isEmpty, canvas.width > 0, canvas.height > 0 else { return nil }
            scale = canvas.height / 1080
            style = title.style
            self.brand = brand
            self.canvas = canvas
            let size = CGFloat(title.style.sizePt) * scale
            let isLowerThird = title.style.position == .lowerThird
            logo = isLowerThird ? logoImage(brand.logo) : nil
            let maxWidth = canvas.width * 0.84 - (logo == nil ? 0 : size * 2)
            let foreground = color(title.style.color) ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            lines = texts.enumerated().map { index, entry in
                // The first line is the name or headline; the rest are smaller, like a lower third's second line.
                let lineSize = index == 0 ? size : size * 0.72
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font(
                        title.style.fontFamily, size: lineSize, bold: index == 0),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
                ]
                var line = CTLineCreateWithAttributedString(NSAttributedString(string: entry.text, attributes: attributes))
                if CTLineGetTypographicBounds(line, nil, nil, nil) > maxWidth {
                    let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                    line = CTLineCreateTruncatedLine(line, maxWidth, .end, ellipsis) ?? line
                }
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
                return Line(line: line, width: width, ascent: ascent, descent: descent, rightToLeft: isRightToLeft(entry.locale))
            }
            rightToLeft = lines.first?.rightToLeft ?? false
            lineGap = size * 0.18
            let textWidth = lines.map(\.width).max() ?? 0
            let textHeight = lines.reduce(0) { $0 + $1.ascent + $1.descent } + lineGap * CGFloat(lines.count - 1)
            let hasBox = title.style.background != nil
            padding = hasBox ? CGSize(width: size * 0.6, height: size * 0.36) : CGSize(width: 0, height: 0)
            logoSide = logo == nil ? 0 : textHeight
            logoSpace = logo == nil ? 0 : logoSide + size * 0.45
            let boxSize = CGSize(width: textWidth + logoSpace + padding.width * 2, height: textHeight + padding.height * 2)
            let x: CGFloat
            let y: CGFloat
            switch title.style.position {
            case .lowerThird:
                let margin = canvas.width * 0.06
                // The kit's side reads from the title's own script: start is the right edge for Arabic.
                let side = brand.kit.lowerThird.position
                let atLeft = (side == .start) != rightToLeft
                x =
                    side == .center
                    ? (canvas.width - boxSize.width) / 2 : atLeft ? margin : canvas.width - margin - boxSize.width
                y = canvas.height * 0.86 - boxSize.height
            case .top:
                x = (canvas.width - boxSize.width) / 2
                y = canvas.height * 0.08
            case .center:
                x = (canvas.width - boxSize.width) / 2
                y = (canvas.height - boxSize.height) / 2
            }
            box = CGRect(origin: CGPoint(x: x, y: y), size: boxSize)
        }

        func draw(in context: CGContext) {
            context.saveGState()
            // CoreGraphics is bottom-left; everything here was laid out top-left.
            context.translateBy(x: 0, y: canvas.height)
            context.scaleBy(x: 1, y: -1)
            drawBackground(in: context)
            let content = box.insetBy(dx: padding.width, dy: padding.height)
            var textRect = content
            if let logo {
                let logoRect = CGRect(
                    x: rightToLeft ? content.maxX - logoSide : content.minX, y: content.minY, width: logoSide,
                    height: logoSide)
                drawImage(logo, in: logoRect, context: context)
                let used = logoSpace
                textRect =
                    rightToLeft
                    ? CGRect(x: content.minX, y: content.minY, width: content.width - used, height: content.height)
                    : CGRect(x: content.minX + used, y: content.minY, width: content.width - used, height: content.height)
            }
            let shadow = style.background == nil
            if shadow {
                context.setShadow(
                    offset: CGSize(width: 0, height: 2 * scale), blur: 8 * scale,
                    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.75))
            }
            var top = textRect.minY
            for line in lines {
                let baseline = top + line.ascent
                // Every line keeps the block's reading side; centred titles centre each line.
                let x: CGFloat =
                    style.position == .lowerThird
                    ? (rightToLeft ? textRect.maxX - line.width : textRect.minX)
                    : textRect.midX - line.width / 2
                context.saveGState()
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line.line, context)
                context.restoreGState()
                top = baseline + line.descent + lineGap
            }
            context.restoreGState()
        }

        private func drawBackground(in context: CGContext) {
            let kitStyle = brand.kit.lowerThird.style
            if let fill = TitleRenderer.color(style.background, alpha: 0.92) {
                let radius = kitStyle == .box || style.position != .lowerThird ? padding.height * 0.7 : 0
                context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(fill)
                context.fillPath()
                if style.position == .lowerThird, kitStyle == .bar, let accent = TitleRenderer.color(brand.kit.colors.primary) {
                    let stripe = max(3, 6 * scale)
                    let x = rightToLeft ? box.maxX - stripe : box.minX
                    context.setFillColor(accent)
                    context.fill(CGRect(x: x, y: box.minY, width: stripe, height: box.height))
                }
            } else if style.position == .lowerThird, kitStyle == .minimal,
                let accent = TitleRenderer.color(brand.kit.colors.primary)
            {
                context.setFillColor(accent)
                context.fill(CGRect(x: box.minX, y: box.maxY + 6 * scale, width: box.width, height: max(2, 4 * scale)))
            }
        }

        private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
            let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            let fitted =
                aspect >= 1
                ? CGRect(x: rect.minX, y: rect.midY - rect.width / aspect / 2, width: rect.width, height: rect.width / aspect)
                : CGRect(x: rect.midX - rect.height * aspect / 2, y: rect.minY, width: rect.height * aspect, height: rect.height)
            context.saveGState()
            // Images draw upright in bottom-left space; flip back for this rect.
            context.translateBy(x: 0, y: fitted.maxY + fitted.minY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: fitted)
            context.restoreGState()
        }
    }
}

import AUNCoreBridge
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Draws one title over a transparent frame with CoreText, so Arabic shapes and runs right to left inside the title.
/// The editor's preview and the export use the same images, so what the creator sees is what is rendered. The layout
/// follows the Desktop editor's `TitleLayout` (same sizes, margins and sides), so a project looks the same in every app.
public enum TitleRenderer {
    /// Where the title's block sits on a frame of `canvas` (top-left origin), for tests.
    public struct Layout: Equatable, Sendable {
        public var box: CGRect
        public var rightToLeft: Bool
        public var hasBox: Bool
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
        Placement(title, brand: brand, canvas: CGSize(width: width, height: height))?.draw(in: context)
        return context.makeImage()
    }

    /// The title's block on the frame (top-left origin), or nil when it has no text.
    public static func layout(_ title: FlattenedTimeline.Title, brand: TitleBrand, canvas: CGSize) -> Layout? {
        Placement(title, brand: brand, canvas: canvas).map {
            Layout(box: $0.block, rightToLeft: $0.rightToLeft, hasBox: $0.background != nil)
        }
    }

    /// Points are 1/72 inch at 96 dpi on a 720-line picture, scaled with the picture height (as on Desktop).
    public static func fontPixels(_ sizePt: Double, height: CGFloat) -> CGFloat {
        CGFloat(sizePt) * 96 / 72 * height / 720
    }

    // MARK: Fonts, colours, direction

    static func font(_ family: String, size: CGFloat, bold: Bool) -> CTFont {
        let named = CTFontCreateWithName(family as CFString, size, nil)
        if (CTFontCopyFamilyName(named) as String).caseInsensitiveCompare(family) == .orderedSame {
            return bold ? CTFontCreateCopyWithSymbolicTraits(named, size, nil, .traitBold, .traitBold) ?? named : named
        }
        // Not installed: the system's interface font (SF Pro, with SF Arabic for Arabic).
        return CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? named
    }

    static func color(_ hex: String?, alpha: CGFloat = 1) -> CGColor? {
        guard let hex, let rgb = TitleBrand.rgb(hex) else { return nil }
        return CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    /// True when text should run right to left: its first letter is Arabic, Hebrew, Syriac, Thaana or N'Ko.
    public static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x0590...0x08FF).contains(value) || (0xFB1D...0xFDFF).contains(value) || (0xFE70...0xFEFF).contains(value) {
                return true
            }
            if scalar.properties.isAlphabetic { return false }
        }
        return false
    }

    static func logoImage(_ data: Data?) -> CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// One line of the title, shaped and wrapped by CoreText.
    struct Line {
        let setter: CTFramesetter
        let length: Int
        let size: CGSize
        var rect = CGRect.zero

        init(_ text: String, rightToLeft: Bool, alignment: CTTextAlignment, font: CTFont, color: CGColor, wrap: CGFloat) {
            var alignment = alignment
            var direction: CTWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
            let paragraph = withUnsafePointer(to: &alignment) { alignmentPointer in
                withUnsafePointer(to: &direction) { directionPointer in
                    let settings = [
                        CTParagraphStyleSetting(
                            spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentPointer),
                        CTParagraphStyleSetting(
                            spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size,
                            value: directionPointer),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
            let string = NSAttributedString(
                string: text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                    NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
                ])
            setter = CTFramesetterCreateWithAttributedString(string)
            length = string.length
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                setter, CFRange(location: 0, length: 0), nil, CGSize(width: wrap, height: .greatestFiniteMagnitude), nil)
            size = CGSize(width: min(ceil(suggested.width), wrap), height: ceil(suggested.height))
        }

        /// Draws in bottom-left space at `target`.
        func draw(at target: CGRect, in context: CGContext) {
            // One point of slack so the measured width never wraps differently when drawn.
            let path = CGPath(
                rect: CGRect(x: target.minX, y: target.minY, width: target.width + 1, height: target.height), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: length), path, nil), context)
        }
    }

    /// The title laid out on the frame, in top-left coordinates.
    struct Placement {
        var lines: [Line] = []
        var block = CGRect.zero
        var background: CGColor?
        var accent: CGRect?
        var accentColor: CGColor?
        var logo: (image: CGImage, rect: CGRect)?
        var rightToLeft = false
        var shadow: CGFloat = 0

        init?(_ title: FlattenedTimeline.Title, brand: TitleBrand, canvas: CGSize) {
            let texts = title.lines
            guard !texts.isEmpty, canvas.width > 0, canvas.height > 0 else { return nil }
            let (width, height) = (canvas.width, canvas.height)
            let style = title.style
            let kit = brand.kit
            let px = fontPixels(style.sizePt, height: height)
            let centered = style.position == .center
            let minimal = kit.lowerThird.style == .minimal && !centered
            let hasBox = style.background != nil && !minimal
            rightToLeft = isRightToLeft(texts[0].text)
            let safeX = width * 0.05
            let pad = hasBox ? px * 0.45 : 0
            let accentWidth = !centered && hasBox && kit.lowerThird.style == .bar ? max(2, px * 0.16) : 0
            let gap = px * 0.15
            let logoGap = px * 0.4
            let logoImage = centered ? nil : TitleRenderer.logoImage(brand.logo)
            let aspect = logoImage.map { min(2.5, max(0, CGFloat($0.width) / CGFloat(max(1, $0.height)))) } ?? 0
            let withLogo = logoImage != nil && aspect > 0

            // Lower thirds take at most 62% of the width (they leave the picture visible); centred titles the safe
            // width. The logo's estimated width is reserved first.
            let estimate = px * 1.25 + (texts.count > 1 ? px * 0.72 * 1.25 * CGFloat(texts.count - 1) : 0)
            let reserved = withLogo ? estimate * aspect + logoGap : 0
            let limit = centered ? width - 2 * safeX : min(width * 0.62, width - 2 * safeX)
            let wrap = max(px * 2, limit - 2 * pad - accentWidth - reserved)

            let foreground = color(style.color) ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let alignment: CTTextAlignment = centered ? .center : (rightToLeft ? .right : .left)
            lines = texts.enumerated().map { index, entry in
                Line(
                    entry.text, rightToLeft: isRightToLeft(entry.text), alignment: alignment,
                    font: font(style.fontFamily, size: index == 0 ? px : px * 0.72, bold: index == 0), color: foreground,
                    wrap: wrap)
            }

            let textWidth = lines.map(\.size.width).max() ?? 0
            let textHeight = lines.reduce(0) { $0 + $1.size.height } + gap * CGFloat(max(0, lines.count - 1))
            let logoHeight = withLogo ? textHeight : 0
            let logoWidth = logoHeight * aspect
            let contentWidth = accentWidth + pad + (withLogo ? logoWidth + logoGap : 0) + textWidth + pad
            let boxWidth =
                kit.lowerThird.style == .bar && hasBox ? max(contentWidth, min(width * 0.45, width - 2 * safeX)) : contentWidth
            let boxHeight = textHeight + 2 * pad

            let x: CGFloat
            if centered || kit.lowerThird.position == .center {
                x = (width - boxWidth) / 2
            } else {
                let atLeft = (kit.lowerThird.position == .start) != rightToLeft
                x = atLeft ? safeX : width - safeX - boxWidth
            }
            let y: CGFloat =
                switch style.position {
                case .center: (height - boxHeight) / 2
                case .top: height * 0.08
                case .lowerThird: height - height * 0.08 - boxHeight
                }
            block = CGRect(x: x, y: y, width: boxWidth, height: boxHeight)

            // From the start side: the accent stripe, the logo, then the text.
            let startEdge = rightToLeft ? x + boxWidth : x
            let rtl = rightToLeft
            func inward(_ offset: CGFloat, _ size: CGFloat) -> CGFloat { rtl ? startEdge - offset - size : startEdge + offset }
            if minimal {
                accent = CGRect(x: x, y: y + boxHeight + px * 0.12, width: max(textWidth, px), height: max(2, px * 0.08))
            } else if accentWidth > 0 {
                accent = CGRect(x: inward(0, accentWidth), y: y, width: accentWidth, height: boxHeight)
            }
            accentColor = color(kit.colors.primary) ?? color(BrandKit.defaultColors.primary)
            background = hasBox ? color(style.background, alpha: 0.92) : nil
            if withLogo, let logoImage {
                logo = (
                    logoImage, CGRect(x: inward(accentWidth + pad, logoWidth), y: y + pad, width: logoWidth, height: logoHeight)
                )
            }
            let textOffset = accentWidth + pad + (withLogo ? logoWidth + logoGap : 0)
            var top = y + pad
            for index in lines.indices {
                let size = lines[index].size
                let lineX: CGFloat =
                    centered || (kit.lowerThird.position == .center && !hasBox)
                    ? x + (boxWidth - size.width) / 2
                    : rtl ? startEdge - textOffset - size.width : startEdge + textOffset
                lines[index].rect = CGRect(x: lineX, y: top, width: size.width, height: size.height)
                top += size.height + gap
            }
            shadow = hasBox ? 0 : max(2, px * 0.1)
        }

        func draw(in context: CGContext) {
            let height = CGFloat(context.height)
            // Laid out top-left; CoreGraphics draws bottom-left.
            func flipped(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
            }
            if let background {
                context.setFillColor(background)
                context.fill(flipped(block))
            }
            if let accent, let accentColor {
                context.setFillColor(accentColor)
                context.fill(flipped(accent))
            }
            if let logo { context.draw(logo.image, in: flipped(logo.rect)) }
            context.saveGState()
            if shadow > 0 {
                context.setShadow(
                    offset: CGSize(width: 0, height: -shadow / 2), blur: shadow * 2,
                    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.75))
            }
            context.textMatrix = .identity
            for line in lines { line.draw(at: flipped(line.rect), in: context) }
            context.restoreGState()
        }
    }
}

import SwiftUI
import Testing

@testable import AUNPlayer

/// Every player icon sits on the centre of its control within ±1px: symmetric glyphs by their ink box, the play
/// triangle by its area centroid (its optical centre). Measured at 4× from the rendered pixels.
@MainActor @Suite struct PlayerIconAlignmentTests {
    struct Ink {
        var boxCentre: CGPoint
        var centroid: CGPoint
        var size: CGSize
    }

    static func ink(of view: some View, side: CGFloat, scale: CGFloat = 4) throws -> Ink {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side))
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var (minX, minY, maxX, maxY) = (width, height, -1, -1)
        var (sumX, sumY, total) = (0.0, 0.0, 0.0)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = Double(pixels[(y * width + x) * 4 + 3]) / 255
                guard alpha > 0.02 else { continue }
                sumX += (Double(x) + 0.5) * alpha
                sumY += (Double(y) + 0.5) * alpha
                total += alpha
                if alpha > 0.5 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        try #require(total > 0 && maxX >= minX, "nothing was drawn")
        let box = CGPoint(x: Double(minX + maxX + 1) / 2 / scale, y: Double(minY + maxY + 1) / 2 / scale)
        return Ink(
            boxCentre: box, centroid: CGPoint(x: sumX / total / scale, y: sumY / total / scale),
            size: CGSize(width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale))
    }

    static func offset(_ icon: PlayerIcon, _ ink: Ink, side: CGFloat) -> CGSize {
        let point = icon.centresByMass ? ink.centroid : ink.boxCentre
        return CGSize(width: point.x - side / 2, height: point.y - side / 2)
    }

    @Test(arguments: PlayerIcon.allCases)
    func barIconIsCentredInItsControl(_ icon: PlayerIcon) throws {
        let ink = try Self.ink(of: PlayerIconGlyph(icon).foregroundStyle(.white).frame(width: 44, height: 44), side: 44)
        let off = Self.offset(icon, ink, side: 44)
        #expect(abs(off.width) <= 1 && abs(off.height) <= 1, "\(icon) is off by \(off)")
        #expect(ink.size.width > 8 && ink.size.width <= 22.5, "\(icon) draws \(ink.size) in a 22pt icon box")
    }

    @Test func bigPlayTriangleIsCentredInTheButton() throws {
        let ink = try Self.ink(
            of: PlayerIconGlyph(.play, size: 32).foregroundStyle(.white).frame(width: 76, height: 76), side: 76)
        let off = Self.offset(.play, ink, side: 76)
        #expect(abs(off.width) <= 1 && abs(off.height) <= 1, "big play is off by \(off)")
    }

    @Test func centringHoldsInArabic() throws {
        for icon in PlayerIcon.allCases {
            let view = PlayerIconGlyph(icon).foregroundStyle(.white).frame(width: 44, height: 44)
                .environment(\.layoutDirection, .rightToLeft)
            let off = Self.offset(icon, try Self.ink(of: view, side: 44), side: 44)
            #expect(abs(off.width) <= 1 && abs(off.height) <= 1, "\(icon) in RTL is off by \(off)")
        }
    }
}

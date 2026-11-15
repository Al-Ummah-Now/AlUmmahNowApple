// App icons from the site's lantern logo (the same mark and colour as the Android launcher icon):
//   swift scripts/make-app-icons.swift <logo.png>
// <logo.png> is AlUmmahNow apps/web/public/logo.png (1000×1000, the round lantern). Writes Assets.xcassets for every
// app target: iOS single-size 1024 (opaque), macOS sizes 16-1024 (rounded tile on a transparent canvas), and the tvOS
// brand assets (layered icons and top shelf images).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let background = CGColor(srgbRed: 0x09 / 255.0, green: 0x30 / 255.0, blue: 0x41 / 255.0, alpha: 1)

guard CommandLine.arguments.count == 2,
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
    let logo = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-app-icons.swift <logo.png>\n".utf8))
    exit(2)
}

func render(_ width: Int, _ height: Int, opaque: Bool, _ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
    context.interpolationQuality = .high
    draw(context)
    return context.makeImage()!
}

func write(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func json(_ object: Any, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

/// The logo centred, `fraction` of the shorter side.
func drawLogo(_ context: CGContext, _ width: Int, _ height: Int, fraction: Double) {
    let side = Double(min(width, height)) * fraction
    context.draw(
        logo, in: CGRect(x: (Double(width) - side) / 2, y: (Double(height) - side) / 2, width: side, height: side))
}

let info = ["author": "xcode", "version": 1] as [String: Any]

// iOS: one opaque 1024 image; the system applies the mask. Logo at 62 % like the Android adaptive icon.
let ios = render(1024, 1024, opaque: true) { context in
    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    drawLogo(context, 1024, 1024, fraction: 0.62)
}

// macOS: Apple's grid, an 824 tile with 185 radius on a 1024 canvas.
let mac = render(1024, 1024, opaque: false) { context in
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    context.setFillColor(background)
    context.fillPath()
    drawLogo(context, 1024, 1024, fraction: 0.52)
}
func scaled(_ image: CGImage, _ side: Int) -> CGImage {
    render(side, side, opaque: false) { $0.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side)) }
}

func iosIcon(_ app: String) {
    let set = "Apps/\(app)/Assets.xcassets/AppIcon.appiconset"
    write(ios, "\(set)/AppIcon-1024.png")
    json(
        ["images": [["filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]], "info": info],
        "\(set)/Contents.json")
    json(["info": info], "Apps/\(app)/Assets.xcassets/Contents.json")
}

func macIcon(_ app: String) {
    let set = "Apps/\(app)/Assets.xcassets/AppIcon.appiconset"
    var images: [[String: String]] = []
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "AppIcon-\(size)@\(scale)x.png"
            write(scaled(mac, size * scale), "\(set)/\(name)")
            images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
        }
    }
    json(["images": images, "info": info], "\(set)/Contents.json")
    json(["info": info], "Apps/\(app)/Assets.xcassets/Contents.json")
}

/// A tvOS layered icon: Back (the colour) and Front (the logo), each @1x and @2x.
func imageStack(_ path: String, _ width: Int, _ height: Int, logoFraction: Double) {
    json(["info": info, "layers": [["filename": "Front.imagestacklayer"], ["filename": "Back.imagestacklayer"]]], "\(path)/Contents.json")
    for (layer, draw) in [
        ("Back", { (c: CGContext, w: Int, h: Int) in c.setFillColor(background); c.fill(CGRect(x: 0, y: 0, width: w, height: h)) }),
        ("Front", { (c: CGContext, w: Int, h: Int) in drawLogo(c, w, h, fraction: logoFraction) }),
    ] {
        let dir = "\(path)/\(layer).imagestacklayer"
        json(["info": info], "\(dir)/Contents.json")
        var images: [[String: String]] = []
        for scale in [1, 2] where !(width >= 1280 && scale == 2) {
            let name = "\(layer)@\(scale)x.png"
            let (w, h) = (width * scale, height * scale)
            write(render(w, h, opaque: layer == "Back") { draw($0, w, h) }, "\(dir)/Content.imageset/\(name)")
            images.append(["filename": name, "idiom": "tv", "scale": "\(scale)x"])
        }
        json(["images": images, "info": info], "\(dir)/Content.imageset/Contents.json")
    }
}

func topShelf(_ path: String, _ width: Int, _ height: Int) {
    var images: [[String: String]] = []
    for scale in [1, 2] {
        let name = "TopShelf@\(scale)x.png"
        let (w, h) = (width * scale, height * scale)
        write(
            render(w, h, opaque: true) { context in
                context.setFillColor(background)
                context.fill(CGRect(x: 0, y: 0, width: w, height: h))
                drawLogo(context, w, h, fraction: 0.7)
            }, "\(path)/\(name)")
        images.append(["filename": name, "idiom": "tv", "scale": "\(scale)x"])
    }
    json(["images": images, "info": info], "\(path)/Contents.json")
}

func tvIcon(_ app: String) {
    let brand = "Apps/\(app)/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
    imageStack("\(brand)/App Icon.imagestack", 400, 240, logoFraction: 0.8)
    imageStack("\(brand)/App Icon - App Store.imagestack", 1280, 768, logoFraction: 0.8)
    topShelf("\(brand)/Top Shelf Image.imageset", 1920, 720)
    topShelf("\(brand)/Top Shelf Image Wide.imageset", 2320, 720)
    json(
        [
            "assets": [
                ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
                ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
                ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
                ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
            ], "info": info,
        ], "\(brand)/Contents.json")
    json(["info": info], "Apps/\(app)/Assets.xcassets/Contents.json")
}

for app in ["ViewerIOS", "StudioIOS", "AdminIOS"] { iosIcon(app) }
for app in ["ViewerMac", "StudioMac", "AdminMac"] { macIcon(app) }
tvIcon("ViewerTV")
print("app icons written")

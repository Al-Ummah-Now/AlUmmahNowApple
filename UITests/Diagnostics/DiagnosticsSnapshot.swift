import UIKit
import XCTest

/// Captures the Diagnostics row from the presented system menu or Accounts form on the CI iPhone.
@MainActor
enum DiagnosticsSnapshot {
    static func launch(_ language: String, _ theme: String) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Diagnostics references use the CI iPhone")
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNLanguage", language, "-AUNTheme", theme,
            "-AUNTelemetryEnabled", "NO", "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    static func capture(
        _ control: XCUIElement, app: XCUIApplication, language: String, theme: String, test: XCTestCase,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let label = title(language)
        XCTAssertTrue(control.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(control.isHittable, file: file, line: line)
        XCTAssertEqual(control.label, label, file: file, line: line)

        let name = "diagnostics-\(language)-\(theme)"
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)

        let actual = control.screenshot()
        let directory = URL(fileURLWithPath: String(describing: file)).deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/DiagnosticsSnapshotTests", isDirectory: true)
        let reference = directory.appendingPathComponent(name + ".png")
        if ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
            || !FileManager.default.fileExists(atPath: reference.path)
        {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try actual.pngRepresentation.write(to: reference)
            XCTFail("Recorded Diagnostics reference at \(reference.path)", file: file, line: line)
            return
        }

        let expected = try XCTUnwrap(UIImage(contentsOfFile: reference.path)?.cgImage, file: file, line: line)
        let captured = try XCTUnwrap(actual.image.cgImage, file: file, line: line)
        XCTAssertEqual(captured.width, expected.width, file: file, line: line)
        XCTAssertEqual(captured.height, expected.height, file: file, line: line)
        let first = try XCTUnwrap(pixels(captured), file: file, line: line)
        let second = try XCTUnwrap(pixels(expected), file: file, line: line)
        // Ignore small antialiasing differences and require at least 97% of pixels to agree.
        let changed = stride(from: 0, to: first.count, by: 4).count { index in
            (index..<(index + 3)).contains { abs(Int(first[$0]) - Int(second[$0])) > 12 }
        }
        let difference = Double(changed) / Double(captured.width * captured.height)
        XCTAssertLessThanOrEqual(difference, 0.03, "\(name) changed by \(difference * 100)%", file: file, line: line)
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func title(_ language: String) -> String {
        language == "ar" ? "التشخيص وتقارير الأعطال" : "Diagnostics & crash reports"
    }

    static func control(_ app: XCUIApplication, identifier: String, language: String) -> XCUIElement {
        // UIKit can expose a SwiftUI Menu action by its localized title instead of its identifier.
        let label = title(language)
        return app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label))
            .firstMatch
    }
}

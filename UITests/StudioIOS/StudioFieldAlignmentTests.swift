import XCTest

/// A field's placeholder and text start where the line starts: at the left in English, at the right in Arabic (#112
/// review). XCUITest cannot ask where the glyphs are, so the test looks at the field's own pixels.
final class StudioFieldAlignmentTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNSampleVideos", "1", "-AUNLanguage", language,
            "-AUNTheme", "light", "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func tab(_ app: XCUIApplication, _ name: String) {
        let candidates = [
            app.tabBars.buttons[name], app.buttons[name].firstMatch, app.cells[name].firstMatch,
            app.cells.containing(.staticText, identifier: name).firstMatch,
        ]
        for _ in 0..<20 {
            if let target = candidates.first(where: { $0.exists && $0.isHittable }) {
                target.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("Expected visible tab or sidebar item: \(name)")
    }

    /// The share of the field's width left of its first drawn pixel and right of its last.
    @MainActor
    private func gaps(_ element: XCUIElement) throws -> (left: Double, right: Double) {
        let image = try XCTUnwrap(element.screenshot().image.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let background = (0..<3).map { Int(pixels[$0]) }
        var first = width
        var last = -1
        for x in 0..<width {
            for y in 0..<height {
                let offset = (y * width + x) * 4
                if (0..<3).reduce(0, { $0 + abs(Int(pixels[offset + $1]) - background[$1]) }) > 90 {
                    first = min(first, x)
                    last = max(last, x)
                    break
                }
            }
        }
        XCTAssertGreaterThanOrEqual(last, 0, "nothing is drawn in \(element.identifier)")
        return (Double(first) / Double(width), Double(width - 1 - last) / Double(width))
    }

    @MainActor
    private func assertStarts(_ element: XCUIElement, rightToLeft: Bool, _ what: String) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 20), what)
        let gap = try gaps(element)
        if rightToLeft {
            XCTAssertLessThan(gap.right, 0.05, "\(what) starts at the right (left \(gap.left), right \(gap.right))")
        } else {
            XCTAssertLessThan(gap.left, 0.05, "\(what) starts at the left (left \(gap.left), right \(gap.right))")
        }
    }

    @MainActor
    func testUploadFieldsStartWhereTheLineStarts() throws {
        for (language, uploadTab, arabic) in [("en", "Upload", false), ("ar", "رفع", true)] {
            let app = launch(language)
            tab(app, uploadTab)
            try assertStarts(app.textFields["upload-title-0"], rightToLeft: arabic, "\(language) video title placeholder")
            try assertStarts(app.textFields["upload-pattern"], rightToLeft: arabic, "\(language) title pattern {{filename}}")
            let description = app.descendants(matching: .any)["upload-description"].firstMatch
            try assertStarts(description, rightToLeft: arabic, "\(language) description placeholder")
            let tags = app.textFields["upload-tags"]
            for _ in 0..<6 where !(tags.exists && tags.isHittable) { app.swipeUp() }
            try assertStarts(tags, rightToLeft: arabic, "\(language) tags placeholder")
            if arabic {
                tags.tap()
                tags.typeText("تفسير")
                try assertStarts(tags, rightToLeft: true, "typed Arabic tags")
            }
            app.terminate()
        }
    }

    @MainActor
    func testEditSheetFieldsStartWhereTheLineStarts() throws {
        for (language, contentTab, arabic) in [("en", "Content", false), ("ar", "المحتوى", true)] {
            let app = launch(language)
            tab(app, contentTab)
            let first = app.descendants(matching: .any).matching(identifier: "video-fixture-content-1").firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 20))
            first.tap()
            try assertStarts(app.textFields["edit-title"], rightToLeft: arabic, "\(language) edit title")
            let description = app.descendants(matching: .any)["edit-description"].firstMatch
            try assertStarts(description, rightToLeft: arabic, "\(language) edit description")
            app.terminate()
        }
    }
}

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

    /// The share of the field's width left of its first drawn pixel and right of its last.
    @MainActor
    private func gaps(_ element: XCUIElement, insideBorder: Bool) throws -> (left: Double, right: Double) {
        let screenshot = try XCTUnwrap(element.screenshot().image.cgImage)
        // Ignore the rounded border and focus ring when inspecting a bordered field.
        let edge = CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height)
        let image =
            insideBorder
            ? try XCTUnwrap(screenshot.cropping(to: edge.insetBy(dx: edge.width * 0.015, dy: edge.height * 0.20)))
            : screenshot
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
    private func assertStarts(_ element: XCUIElement, rightToLeft: Bool, _ what: String, insideBorder: Bool = false) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 20), what)
        let gap = try gaps(element, insideBorder: insideBorder)
        if rightToLeft {
            if insideBorder { XCTAssertGreaterThan(gap.left, 0.5, "the field chrome is excluded") }
            XCTAssertLessThan(
                gap.right, insideBorder ? 0.09 : 0.05, "\(what) starts at the right (left \(gap.left), right \(gap.right))")
        } else {
            XCTAssertLessThan(gap.left, 0.05, "\(what) starts at the left (left \(gap.left), right \(gap.right))")
        }
    }

    @MainActor
    func testUploadFieldsStartWhereTheLineStarts() throws {
        for (language, uploadTab, arabic) in [("en", "Upload", false), ("ar", "رفع", true)] {
            let app = launch(language)
            app.openStudioTab(named: uploadTab)
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
            app.openStudioTab(named: contentTab)
            let first = app.descendants(matching: .any).matching(identifier: "video-fixture-content-1").firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 20))
            first.tap()
            let heading = app.staticTexts["edit-heading"]
            XCTAssertTrue(heading.waitForExistence(timeout: 15))
            XCTAssertEqual(heading.label, arabic ? "تعديل المرئي" : "Edit video")
            try assertStarts(app.textFields["edit-title"], rightToLeft: arabic, "\(language) edit title")
            let description = app.descendants(matching: .any)["edit-description"].firstMatch
            try assertStarts(description, rightToLeft: arabic, "\(language) edit description")
            app.terminate()
        }
    }
    @MainActor
    func testArabicDeletionPromptAndTypedWordStartAtTheRight() throws {
        let app = launch("ar")
        let identity = app.descendants(matching: .any)["account-button"].firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 20))
        identity.tap()
        app.accountsMenuItem.tap()
        let delete = app.buttons["account-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()

        let input = app.textFields["delete-account-confirm-input"]
        let confirm = app.buttons["delete-account-confirm"]
        try assertStarts(input, rightToLeft: true, "Arabic deletion prompt", insideBorder: true)
        XCTAssertFalse(confirm.isEnabled)
        input.tap()
        input.typeText("حذف")
        try assertStarts(input, rightToLeft: true, "typed Arabic deletion word", insideBorder: true)
        XCTAssertTrue(confirm.isEnabled)
    }
}

import XCTest

final class ViewerFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AUNUseFixtures", "YES", "-AUNLanguage", language, "-AUNTheme", "dark"]
        app.launch()
        return app
    }

    private let firstCard = "video-card-trending-fixture-1"

    @MainActor
    private func card(_ app: XCUIApplication) -> XCUIElement {
        let element = app.buttons[firstCard]
        XCTAssertTrue(element.waitForExistence(timeout: 30))
        return element
    }

    @MainActor
    func testEnglishLayoutStartsAtLeading() {
        let app = launch("en")
        let frame = card(app).frame
        XCTAssertLessThan(frame.midX, app.windows.firstMatch.frame.midX + frame.width / 2)
        XCTAssertLessThan(frame.minX, 40)
    }

    @MainActor
    func testArabicLayoutIsMirrored() {
        let app = launch("ar")
        let frame = card(app).frame
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(frame.maxX, window.maxX - 40, "first card must sit at the right edge in RTL")
        XCTAssertTrue(app.staticTexts["الأكثر رواجًا"].exists)
    }

    @MainActor
    func testWatchPageShowsLocalizedContentAndControls() {
        let app = launch("ar")
        card(app).tap()
        let title = app.staticTexts["watch-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "المحاضرة 1: مقدمة في التفسير")
        XCTAssertTrue(app.buttons["chapter-c1"].exists)
        XCTAssertTrue(app.buttons["subtitles-menu"].exists)
        XCTAssertTrue(app.buttons["speed-menu"].exists)
        XCTAssertTrue(app.buttons["quality-menu"].exists)
    }

    @MainActor
    func testQualityMenuListsRenditionsAndSkipControlsMirror() {
        let app = launch("ar")
        card(app).tap()
        let forward = app.buttons["skip-forward"]
        XCTAssertTrue(forward.waitForExistence(timeout: 20))
        XCTAssertLessThan(forward.frame.midX, app.buttons["skip-back"].frame.midX, "RTL places back on the right")
        app.buttons["quality-menu"].tap()
        XCTAssertTrue(app.buttons["360p"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["تلقائي"].exists)
    }

    @MainActor
    func testLanguageSwitchesWithoutRelaunch() {
        let app = launch("en")
        _ = card(app)
        XCTAssertTrue(app.staticTexts["Trending"].exists)
        app.buttons["settings-menu"].tap()
        app.buttons["العربية"].tap()
        XCTAssertTrue(app.staticTexts["الأكثر رواجًا"].waitForExistence(timeout: 5))
    }
}

import XCTest

final class MacViewerTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AUNUseFixtures", "YES", "-AUNLanguage", language, "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    private let card = "video-card-trending-fixture-1"

    @MainActor
    func testEnglishHome() {
        let app = launch("en")
        XCTAssertTrue(app.buttons[card].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Trending"].exists)
    }

    @MainActor
    func testArabicHomeIsMirrored() {
        let app = launch("ar")
        let element = app.buttons[card]
        XCTAssertTrue(element.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["الأكثر رواجًا"].exists)
        XCTAssertGreaterThan(element.frame.midX, app.windows.firstMatch.frame.midX)
    }

    @MainActor
    func testVideoOpensInItsOwnWindow() {
        let app = launch("en")
        let element = app.buttons[card]
        XCTAssertTrue(element.waitForExistence(timeout: 30))
        // The card can sit below the fold of a small CI screen; the hero's Watch now opens the same window.
        // On the Mac the hero's container identifier covers its children, so find the button by its label.
        let watch = app.buttons["Watch now"].firstMatch
        XCTAssertTrue(watch.waitForExistence(timeout: 10))
        let windows = app.windows.count
        watch.click()
        let title = app.staticTexts["watch-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(app.windows.count, windows)
    }
}

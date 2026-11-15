import XCTest

/// App Store screenshots for iPhone and iPad (scripts/screenshots.sh); skipped in normal test runs.
final class StoreScreenshots: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(StoreScreenshot.enabled, "store screenshots run from scripts/screenshots.sh")
        continueAfterFailure = false
    }

    @MainActor
    func testStoreScreenshots() {
        for language in StoreScreenshot.languages {
            for theme in StoreScreenshot.themes {
                let app = StoreScreenshot.launch(language, theme)
                let card = app.buttons["video-card-trending-fixture-1"]
                XCTAssertTrue(card.waitForExistence(timeout: 30))
                StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 1, name: "home"))
                card.tap()
                XCTAssertTrue(app.staticTexts["watch-title"].waitForExistence(timeout: 20))
                StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 2, name: "watch"))
                app.terminate()
            }
        }
    }
}

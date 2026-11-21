import XCTest

/// Mac App Store screenshots (scripts/screenshots.sh); skipped in normal test runs.
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
                XCTAssertTrue(StoreScreenshot.firstTrendingCard(app).waitForExistence(timeout: 30))
                StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 1, name: "home"))
                // The hero's Watch now opens the video in its own window, which comes to the front.
                let watch = app.buttons[language == "ar" ? "شاهد الآن" : "Watch now"].firstMatch
                if watch.waitForExistence(timeout: 10) {
                    watch.click()
                    XCTAssertTrue(app.staticTexts["watch-title"].waitForExistence(timeout: 20))
                    StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 2, name: "watch"))
                }
                app.terminate()
            }
        }
    }
}

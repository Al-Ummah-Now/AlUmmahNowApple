import XCTest

/// App Store screenshots for Apple TV (scripts/screenshots.sh); skipped in normal test runs.
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
                XCTAssertTrue(app.buttons["hero"].waitForExistence(timeout: 30))
                StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 1, name: "home"))
                XCUIRemote.shared.press(.down)
                StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 2, name: "rail"))
                app.terminate()
            }
        }
    }
}

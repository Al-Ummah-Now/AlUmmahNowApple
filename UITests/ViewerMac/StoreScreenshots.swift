import XCTest

/// Mac App Store screenshots (scripts/screenshots.sh); skipped in normal test runs.
final class StoreScreenshots: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(StoreScreenshot.enabled, "store screenshots run from scripts/screenshots.sh")
        continueAfterFailure = false
    }

    /// Window heights (points) at which each frame ends below whole content, never through a card: the window bottom
    /// is a crop (UITests/Shared/FrameEdges.swift). Home ends between the two Trending rows (cards to 598, from 614), with the 8-point gap.
    /// Watch ends below the chapters (to 725) and between the third and fourth Up next card (to 947, from 963), with the 8-point gap.
    private let size = ["-AUNWindowHeight", "609", "-AUNWatchWindowHeight", "958"]

    @MainActor
    func testStoreScreenshots() {
        for language in StoreScreenshot.languages {
            for theme in StoreScreenshot.themes {
                let app = StoreScreenshot.launch(language, theme, extra: size)
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

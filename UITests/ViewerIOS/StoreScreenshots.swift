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
                let card = StoreScreenshot.firstTrendingCard(app)
                XCTAssertTrue(card.waitForExistence(timeout: 30))
                StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 1, name: "home"))
                card.tap()
                XCTAssertTrue(app.staticTexts["watch-title"].waitForExistence(timeout: 20))
                StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 2, name: "watch"))
                app.terminate()
                if StoreScreenshot.reviewShots {
                    // Home scrolled to a section edge (`-AUNScrollTo`): "Recently added" on iPhone; on iPad, whose screen
                    // holds two rails, "Trending" with "Recently added" under it, so the frame is full to the bottom.
                    let rail = UIDevice.current.userInterfaceIdiom == .pad ? "rail-trending" : "rail-recent"
                    let more = StoreScreenshot.launch(language, theme, extra: ["-AUNScrollTo", rail])
                    // A card of the requested rail, on screen once scrolled to (cards above it may be unloaded, and the
                    // rail itself is not an accessibility element).
                    let card = more.buttons.matching(
                        NSPredicate(format: "identifier BEGINSWITH %@", "video-card-\(rail.dropFirst(5))-")
                    ).firstMatch
                    XCTAssertTrue(card.waitForExistence(timeout: 30))
                    StoreScreenshot.capture(more, self, .init(language: language, theme: theme, index: 3, name: "home-more"))
                    more.terminate()
                }
            }
        }
    }
}

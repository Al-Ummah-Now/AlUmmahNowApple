import XCTest

/// App Store screenshots for iPhone and iPad (scripts/screenshots.sh); skipped in normal test runs.
final class StoreScreenshots: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(StoreScreenshot.enabled, "store screenshots run from scripts/screenshots.sh")
        continueAfterFailure = false
    }

    /// iPhone home starts 95 points down (`-AUNScrollTo home-hero+94`; the hero lands 1 point under the page's top
    /// gap): at the top, the screen's bottom edge cut the title drawn on the next card's art. This far down, the hero's
    /// own art title is under the header and the next card's is whole, 56 points above the edge. iPad home fits.
    private var home: [String] {
        UIDevice.current.userInterfaceIdiom == .pad ? [] : ["-AUNScrollTo", "home-hero+94"]
    }

    @MainActor
    func testStoreScreenshots() {
        for language in StoreScreenshot.languages {
            for theme in StoreScreenshot.themes {
                let app = StoreScreenshot.launch(language, theme, extra: home)
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
                    // Both land by the hero, a set distance down the page (a rail's landing takes no offset, and left
                    // the rail's title 2 points under the header). iPad, 300 points down: "Trending" sits about as far
                    // under the header as the home frame's hero, and the duration badge and title of Recently added's
                    // third row are just off screen. iPhone, 2,311 points down: "Recently added" sits 20 points under
                    // the header, and its third card's badge is off screen below the whole title on its art.
                    let pad = UIDevice.current.userInterfaceIdiom == .pad
                    let rail = pad ? "rail-trending" : "rail-recent"
                    let more = StoreScreenshot.launch(
                        language, theme, extra: ["-AUNScrollTo", pad ? "home-hero+300" : "home-hero+2311"])
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

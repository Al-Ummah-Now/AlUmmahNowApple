import XCTest

/// Mac screenshots for Studio (scripts/screenshots.sh); skipped in normal test runs.
final class StoreScreenshots: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(StoreScreenshot.enabled, "store screenshots run from scripts/screenshots.sh")
        continueAfterFailure = false
    }

    @MainActor
    func testStoreScreenshots() {
        for language in StoreScreenshot.languages {
            for theme in StoreScreenshot.themes {
                let app = StoreScreenshot.launch(language, theme, extra: ["-AUNFixtureSignedIn", "YES"])
                let home = app.descendants(matching: .any)["section-home"]
                XCTAssertTrue(home.waitForExistence(timeout: 30))
                for (index, section) in ["home", "content", "upload", "analytics", "encode"].enumerated() {
                    app.descendants(matching: .any)["section-\(section)"].click()
                    StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: index + 1, name: section))
                }
                app.terminate()
                if StoreScreenshot.reviewShots {
                    // Analytics scrolled to the daily chart with its table open (`-AUNScrollTo analytics-table`), as on iPhone and iPad.
                    let lower = StoreScreenshot.launch(
                        language, theme, extra: ["-AUNFixtureSignedIn", "YES", "-AUNScrollTo", "analytics-table"])
                    XCTAssertTrue(lower.descendants(matching: .any)["section-home"].waitForExistence(timeout: 30))
                    lower.descendants(matching: .any)["section-analytics"].click()
                    StoreScreenshot.capture(
                        lower, self, .init(language: language, theme: theme, index: 6, name: "analytics-lower"))
                    lower.terminate()
                }
            }
        }
    }
}

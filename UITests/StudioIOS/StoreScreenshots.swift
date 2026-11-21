import XCTest

/// App Store screenshots for Studio on iPhone and iPad (scripts/screenshots.sh); skipped in normal test runs.
final class StoreScreenshots: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(StoreScreenshot.enabled, "store screenshots run from scripts/screenshots.sh")
        continueAfterFailure = false
    }

    /// Tab titles (AUNDesign en/ar `studio.*.title`).
    private let tabs: [String: [(key: String, label: String)]] = [
        "en": [("content", "Content"), ("upload", "Upload"), ("analytics", "Analytics")],
        "ar": [("content", "المحتوى"), ("upload", "رفع"), ("analytics", "الإحصاءات")],
    ]

    @MainActor
    private func open(_ app: XCUIApplication, tab: String) {
        // iPhone has a bottom tab bar; iPad opens on the sidebar, whose rows are cells (or buttons on some releases).
        let candidates = [
            app.tabBars.buttons[tab], app.buttons[tab].firstMatch, app.cells[tab].firstMatch,
            app.cells.containing(.staticText, identifier: tab).firstMatch,
        ]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let hit = candidates.first(where: { $0.exists && $0.isHittable }) {
                hit.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("no tab named \(tab)")
    }

    @MainActor
    func testStoreScreenshots() {
        for language in StoreScreenshot.languages {
            for theme in StoreScreenshot.themes {
                let app = StoreScreenshot.launch(language, theme, extra: ["-AUNFixtureSignedIn", "YES"])
                let card = app.descendants(matching: .any).matching(identifier: "account-button").firstMatch
                XCTAssertTrue(card.waitForExistence(timeout: 30))
                StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 1, name: "dashboard"))
                for (offset, tab) in (tabs[language] ?? tabs["en"]!).enumerated() {
                    open(app, tab: tab.label)
                    StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: offset + 2, name: tab.key))
                }
                app.terminate()
                if StoreScreenshot.reviewShots {
                    // Analytics scrolled to the daily chart and top videos (`-AUNScrollTo`).
                    let lower = StoreScreenshot.launch(
                        language, theme, extra: ["-AUNFixtureSignedIn", "YES", "-AUNScrollTo", "analytics-daily"])
                    XCTAssertTrue(
                        lower.descendants(matching: .any).matching(identifier: "account-button").firstMatch
                            .waitForExistence(timeout: 30))
                    open(lower, tab: (tabs[language] ?? tabs["en"]!)[2].label)
                    StoreScreenshot.capture(
                        lower, self, .init(language: language, theme: theme, index: 5, name: "analytics-lower"))
                    lower.terminate()
                }
            }
        }
    }
}

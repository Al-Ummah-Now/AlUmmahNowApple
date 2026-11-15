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
        // iPhone has a bottom tab bar; iPadOS draws the tabs at the top, outside `tabBars`.
        let bar = app.tabBars.buttons[tab]
        let button = bar.waitForExistence(timeout: 10) ? bar : app.buttons[tab].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    @MainActor
    func testStoreScreenshots() {
        for language in StoreScreenshot.languages {
            for theme in StoreScreenshot.themes {
                let app = StoreScreenshot.launch(language, theme, extra: ["-AUNFixtureSignedIn", "YES"])
                let card = app.descendants(matching: .any).matching(identifier: "channel-card").firstMatch
                XCTAssertTrue(card.waitForExistence(timeout: 30))
                StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 1, name: "dashboard"))
                for (offset, tab) in (tabs[language] ?? tabs["en"]!).enumerated() {
                    open(app, tab: tab.label)
                    StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: offset + 2, name: tab.key))
                }
                app.terminate()
            }
        }
    }
}

import XCTest

/// Review screenshots of live (wiki E17), on fixtures; only with `AUN_SCREENSHOTS=1`.
final class LiveScreens: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(StoreScreenshot.enabled, "screenshots run on request")
        continueAfterFailure = true
    }

    @MainActor
    func testLiveScreens() {
        let pages: [(String, [String], String)] = [
            ("home", [], "live-card-fixture-live"),
            ("live", ["-AUNOpenLive", "fixture-live"], "live-title"),
            ("premiere", ["-AUNOpenLive", "fixture-premiere"], "live-countdown"),
            ("coming", ["-AUNOpenLive", "fixture-coming"], "live-notice"),
            ("recording", ["-AUNOpenLive", "fixture-recording"], "live-title"),
        ]
        for language in StoreScreenshot.languages {
            for theme in StoreScreenshot.themes {
                for (index, page) in pages.enumerated() {
                    let app = StoreScreenshot.launch(language, theme, extra: ["-AUNFixtureLive", "YES"] + page.1)
                    XCTAssertTrue(app.descendants(matching: .any)[page.2].firstMatch.waitForExistence(timeout: 30), page.0)
                    StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: index + 1, name: page.0))
                    #if os(iOS)
                        if page.0 == "home" {
                            app.buttons["live-see-all"].tap()
                            XCTAssertTrue(app.buttons["live-event-menu"].waitForExistence(timeout: 20))
                            StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 6, name: "list"))
                        }
                    #endif
                    #if os(iOS)
                        // The chat beside the player, where the screen is wide enough for it
                        if UIDevice.current.userInterfaceIdiom == .pad, page.0 == "live" || page.0 == "recording" {
                            XCUIDevice.shared.orientation = .landscapeLeft
                            let name = page.0 + "-landscape"
                            let shot = StoreScreenshot.Shot(
                                language: language, theme: theme, index: 10 + index, name: name)
                            StoreScreenshot.capture(app, self, shot)
                            XCUIDevice.shared.orientation = .portrait
                        }
                    #endif
                    app.terminate()
                }
            }
        }
    }
}

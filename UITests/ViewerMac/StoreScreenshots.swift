import XCTest

/// Mac App Store screenshots (scripts/screenshots.sh); skipped in normal test runs.
final class StoreScreenshots: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(StoreScreenshot.enabled, "store screenshots run from scripts/screenshots.sh")
        continueAfterFailure = false
    }

    /// Window heights (points) at which each frame ends below whole content, never through a card: the window bottom
    /// is a crop (UITests/Shared/FrameEdges.swift). Home ends between the two Trending rows (cards to 598, from 614)
    /// and Watch below the chapters (to 725) and between the third and fourth Up next card (to 947, from 963), each
    /// with the 8-point gap.
    private let homeHeight: CGFloat = 609
    private let watchHeight: CGFloat = 958
    private var size: [String] {
        ["-AUNWindowHeight", "\(Int(homeHeight))", "-AUNWatchWindowHeight", "\(Int(watchHeight))"]
    }

    /// Launches with the review heights: up to three launches until the window has its height, so the frame is never
    /// taken at another.
    @MainActor
    private func launch(_ language: String, _ theme: String) -> XCUIApplication {
        for _ in 0..<3 {
            let app = StoreScreenshot.launch(language, theme, extra: size)
            XCTAssertTrue(StoreScreenshot.firstTrendingCard(app).waitForExistence(timeout: 30))
            if StoreScreenshot.frontWindow(app, isTall: homeHeight) { return app }
            app.terminate()
        }
        XCTFail("the window never opened \(Int(homeHeight)) points tall")
        return XCUIApplication()
    }

    @MainActor
    func testStoreScreenshots() {
        for language in StoreScreenshot.languages {
            for theme in StoreScreenshot.themes {
                let app = launch(language, theme)
                StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 1, name: "home"))
                // The hero's Watch now opens the video in its own window, which comes to the front.
                let watch = app.buttons[language == "ar" ? "شاهد الآن" : "Watch now"].firstMatch
                if watch.waitForExistence(timeout: 10) {
                    watch.click()
                    XCTAssertTrue(app.staticTexts["watch-title"].waitForExistence(timeout: 20))
                    let opened = Int(app.windows.firstMatch.frame.height)
                    XCTAssertTrue(
                        StoreScreenshot.frontWindow(app, isTall: watchHeight),
                        "the watch window opened \(opened) points tall, not \(Int(watchHeight))")
                    StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 2, name: "watch"))
                }
                app.terminate()
            }
        }
    }
}

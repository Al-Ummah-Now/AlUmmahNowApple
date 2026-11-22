import XCTest

/// Mac screenshots for Studio (scripts/screenshots.sh); skipped in normal test runs.
final class StoreScreenshots: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(StoreScreenshot.enabled, "store screenshots run from scripts/screenshots.sh")
        continueAfterFailure = false
    }

    /// Each section with the window height (points) at which its frame ends below whole content: the window bottom is
    /// a crop, so it falls in the gap between two cards, never through one (UITests/Shared/FrameEdges.swift). The width
    /// stays 1100, so the layout above the edge is the same as at the default height. Every launch names its height
    /// (680 is the default): a launch without one once opened at the previous launch's height.
    private let sections: [(name: String, height: CGFloat)] = [
        // Between Recent uploads (to 584) and Drafts and scheduled (from 600).
        ("home", 592),
        // Between the sixth and seventh video (cards to 635 and from 644).
        ("content", 640),
        ("upload", 680),
        // Between the daily chart (to 648) and Top videos (from 665).
        ("analytics", 656),
        ("encode", 680),
    ]

    /// The lower analytics frame: the daily chart scrolled to the top with its table open (`-AUNScrollTo
    /// analytics-table`), as on iPhone and iPad. The table is taller than any window, so the bottom edge falls between
    /// two of its rows (to 669 and from 681) at the default height.
    private let lowerHeight: CGFloat = 680

    @MainActor
    private func launch(_ language: String, _ theme: String, height: CGFloat, extra: [String] = []) -> XCUIApplication {
        let size = ["-AUNWindowHeight", "\(Int(height))"]
        // Up to three launches until the window has that height; the frame is never taken at another.
        for _ in 0..<3 {
            let app = StoreScreenshot.launch(language, theme, extra: ["-AUNFixtureSignedIn", "YES"] + size + extra)
            XCTAssertTrue(app.descendants(matching: .any)["section-home"].waitForExistence(timeout: 30))
            if StoreScreenshot.frontWindow(app, isTall: height) { return app }
            app.terminate()
        }
        XCTFail("the window never opened \(Int(height)) points tall")
        return XCUIApplication()
    }

    @MainActor
    func testStoreScreenshots() {
        for language in StoreScreenshot.languages {
            for theme in StoreScreenshot.themes {
                // One launch per window height: a window keeps the size it opened at.
                var app: XCUIApplication?
                var openHeight: CGFloat?
                for (index, section) in sections.enumerated() {
                    if openHeight != section.height {
                        app?.terminate()
                        app = launch(language, theme, height: section.height)
                        openHeight = section.height
                    }
                    guard let app else { continue }
                    app.descendants(matching: .any)["section-\(section.name)"].click()
                    StoreScreenshot.capture(
                        app, self, .init(language: language, theme: theme, index: index + 1, name: section.name))
                }
                app?.terminate()
                if StoreScreenshot.reviewShots {
                    let lower = launch(language, theme, height: lowerHeight, extra: ["-AUNScrollTo", "analytics-table"])
                    lower.descendants(matching: .any)["section-analytics"].click()
                    StoreScreenshot.capture(
                        lower, self, .init(language: language, theme: theme, index: 6, name: "analytics-lower"))
                    lower.terminate()
                }
            }
        }
    }
}

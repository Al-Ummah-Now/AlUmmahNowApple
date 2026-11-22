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

    /// The Dashboard tab's title (`studio.home.title`).
    private let dashboard = ["en": "Dashboard", "ar": "لوحة التحكم"]

    @MainActor
    private func open(_ app: XCUIApplication, tab: String) {
        // iPhone has a bottom tab bar; iPad opens on the sidebar, whose rows are cells (or buttons on some releases).
        let candidates = [
            app.tabBars.buttons[tab], app.buttons[tab].firstMatch, app.cells[tab].firstMatch,
            app.cells.containing(.staticText, identifier: tab).firstMatch,
        ]
        // Uptime, not the wall clock: CI holds the clock at 09:41 for the status bar (scripts/screenshots.sh).
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let hit = candidates.first(where: { $0.exists && $0.isHittable }) {
                hit.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("no tab named \(tab)")
    }

    /// Where each frame scrolls (`-AUNScrollTo`), so it ends on whole content (UITests/Shared/FrameEdges.swift): the
    /// last line clears the iPhone tab bar or the iPad screen bottom with a gap, and no row is cut. `nil` is the top of
    /// the page. The table's rows are 36 points apart, so the lower frame lands a few points past the chart's edge.
    private struct Scroll {
        let dashboard: String?
        let analytics: String?
        let lower: String
    }

    private var scroll: Scroll {
        UIDevice.current.userInterfaceIdiom == .pad
            // iPad: the dashboard and analytics fit; the lower frame's last row (Nov 19) ends 10 points up.
            ? Scroll(dashboard: nil, analytics: nil, lower: "analytics-table+21")
            // iPhone: at the top, a comment straddled the tab bar whatever the offset, so the dashboard starts at its
            // sections and ends between the comments and the drafts. Analytics moves 14 points so the chart's dates
            // clear the tab bar; the lower frame 12, so Nov 5 does.
            : Scroll(dashboard: "dashboard-sections", analytics: "analytics-range+14", lower: "analytics-table+12")
    }

    @MainActor
    private func launch(_ language: String, _ theme: String, scrollTo: String?) -> XCUIApplication {
        let target = scrollTo.map { ["-AUNScrollTo", $0] } ?? []
        let app = StoreScreenshot.launch(language, theme, extra: ["-AUNFixtureSignedIn", "YES"] + target)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "account-button").firstMatch.waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    func testStoreScreenshots() {
        let scroll = scroll
        for language in StoreScreenshot.languages {
            let tabs = tabs[language] ?? tabs["en"]!
            for theme in StoreScreenshot.themes {
                let app = launch(language, theme, scrollTo: scroll.dashboard)
                // iPad opens with the sidebar over the page. Choosing another tab closes it, as a person would, and the
                // top tab bar brings Dashboard back, so the frame shows the whole dashboard. iPhone just switches tabs.
                open(app, tab: tabs[0].label)
                open(app, tab: dashboard[language] ?? "Dashboard")
                StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: 1, name: "dashboard"))
                for (offset, tab) in tabs.enumerated() where scroll.analytics == nil || tab.key != "analytics" {
                    open(app, tab: tab.label)
                    StoreScreenshot.capture(app, self, .init(language: language, theme: theme, index: offset + 2, name: tab.key))
                }
                app.terminate()
                if let target = scroll.analytics {
                    let analytics = launch(language, theme, scrollTo: target)
                    open(analytics, tab: tabs[2].label)
                    StoreScreenshot.capture(analytics, self, .init(language: language, theme: theme, index: 4, name: "analytics"))
                    analytics.terminate()
                }
                if StoreScreenshot.reviewShots {
                    // Analytics scrolled to the daily chart with its table open (`-AUNScrollTo analytics-table`).
                    let lower = launch(language, theme, scrollTo: scroll.lower)
                    open(lower, tab: tabs[2].label)
                    StoreScreenshot.capture(
                        lower, self, .init(language: language, theme: theme, index: 5, name: "analytics-lower"))
                    lower.terminate()
                }
            }
        }
    }
}

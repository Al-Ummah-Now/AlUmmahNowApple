import XCTest

/// Account states from `GET /api/me/creator` and the server's refusals, on fixtures. English and Arabic.
final class StudioAccountStateTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String, state: String, featuresOff: String = "") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNFixtureAccountState", state,
            "-AUNFixtureFeaturesOff", featuresOff, "-AUNLanguage", language, "-AUNTheme", "dark",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func openTab(_ app: XCUIApplication, _ name: String) {
        let bar = app.tabBars.buttons[name]
        let button = bar.waitForExistence(timeout: 15) ? bar : app.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
    }

    @MainActor
    func testPendingDeletionShowsOneBannerAndNoUploader() {
        let app = launch("en", state: "pendingDeletion")
        let banner = app.descendants(matching: .any)["account-state"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        // The banner reads as one element: its title, then the message.
        XCTAssertTrue(banner.label.contains("Your videos account is scheduled for deletion. Contact support."))
        openTab(app, "Upload")
        XCTAssertTrue(app.descendants(matching: .any)["upload-refused"].firstMatch.waitForExistence(timeout: 10))
        keep("pending-deletion-en")
    }

    @MainActor
    func testPendingDeletionInArabic() {
        let app = launch("ar", state: "pendingDeletion")
        let banner = app.descendants(matching: .any)["account-state"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        XCTAssertTrue(banner.label.contains("حسابك في المرئيات مجدول للحذف. تواصل مع الدعم."))
        keep("pending-deletion-ar")
    }

    @MainActor
    /// A tab: in the tab bar on iPhone, a button in the top tab bar on iPad.
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    /// Without a creator tier there is no Upload tab and nothing about tiers or invitations (owner rule 2026-11-16).
    @MainActor
    func testNoCreatorTierHasNoUploadTab() {
        let app = launch("en", state: "invitation")
        XCTAssertTrue(tab(app, "Content").waitForExistence(timeout: 30))
        XCTAssertTrue(tab(app, "Analytics").exists)
        XCTAssertFalse(tab(app, "Upload").exists)
        XCTAssertFalse(app.descendants(matching: .any)["upload-refused"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["account-state"].firstMatch.exists)
        keep("no-upload-tab-en")
    }

    @MainActor
    func testNoCreatorTierHasNoUploadTabInArabic() {
        let app = launch("ar", state: "invitation")
        XCTAssertTrue(tab(app, "المحتوى").waitForExistence(timeout: 30))
        XCTAssertFalse(tab(app, "رفع").exists)
        keep("no-upload-tab-ar")
    }

    /// A creator sees Upload; switching the feature off in the fixture hides it.
    @MainActor
    func testUploadTabFollowsTheFeature() {
        let on = launch("en", state: "creator")
        XCTAssertTrue(tab(on, "Upload").waitForExistence(timeout: 30))
        on.terminate()
        let off = launch("en", state: "creator", featuresOff: "upload")
        XCTAssertTrue(tab(off, "Content").waitForExistence(timeout: 30))
        XCTAssertFalse(tab(off, "Upload").exists)
    }

    /// Analytics answering 404 `feature_off` takes the tab away without a message.
    @MainActor
    func testAnalyticsOffHidesItsTab() {
        let app = launch("en", state: "creator", featuresOff: "analytics")
        XCTAssertTrue(tab(app, "Content").waitForExistence(timeout: 30))
        // The tab view may build Analytics before it is tapped; either way the tab goes.
        let analytics = tab(app, "Analytics")
        if analytics.exists { analytics.tap() }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: analytics)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(tab(app, "Dashboard").isSelected)
        XCTAssertFalse(app.staticTexts["We couldn’t load this right now."].exists)
        keep("analytics-off-en")
        assertDashboardSections(app)
    }

    /// No hollow Dashboard (owner review 2026-11-16): with Analytics off it still lists recent uploads, comments awaiting
    /// review, and drafts and scheduled, and every loader has stopped.
    @MainActor
    func testDashboardKeepsItsSectionsWithAnalyticsOff() {
        for language in ["en", "ar"] {
            let app = launch(language, state: "creator", featuresOff: "analytics")
            assertDashboardSections(app)
            app.terminate()
        }
    }

    /// Comments off takes only that section away.
    @MainActor
    func testCommentsOffHidesOnlyThatSection() {
        let app = launch("en", state: "creator", featuresOff: "comments")
        let recent = app.descendants(matching: .any)["dashboard-recent"]
        XCTAssertTrue(recent.waitForExistence(timeout: 30))
        XCTAssertTrue(find(app, "dashboard-queue").exists)
        XCTAssertFalse(app.descendants(matching: .any)["dashboard-held"].exists)
    }

    @MainActor
    private func assertDashboardSections(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let recent = app.descendants(matching: .any)["dashboard-recent"]
        XCTAssertTrue(recent.waitForExistence(timeout: 30), file: file, line: line)
        // Its rows load after the section appears: wait for them rather than counting at once.
        let rows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 1"), object: recent.staticTexts)
        XCTAssertEqual(XCTWaiter.wait(for: [rows], timeout: 15), .completed, "recent uploads empty", file: file, line: line)
        for section in ["dashboard-held", "dashboard-queue"] {
            XCTAssertTrue(find(app, section).exists, "\(section) missing", file: file, line: line)
        }
        let spinning = app.activityIndicators
        expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: spinning)
        waitForExpectations(timeout: 15)
    }

    /// Scrolls down until an element below the fold is on screen.
    @MainActor
    private func find(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        for _ in 0..<4 where !element.exists { app.swipeUp() }
        return element
    }

}

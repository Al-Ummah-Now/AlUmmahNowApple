import XCTest

/// Studio for Mac on fixtures: sign-in, channel picker and sign-out, in English and Arabic.
final class StudioSmokeTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(
        _ language: String, signedIn: Bool = false, state: String = "creator", featuresOff: String = ""
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", signedIn ? "YES" : "NO", "-AUNLanguage", language,
            "-AUNFixtureAccountState", state, "-AUNFixtureFeaturesOff", featuresOff, "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    /// The identity menu: its value is "channel · role · account".
    @MainActor
    private func identity(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "account-button").firstMatch
    }

    @MainActor
    func testEnglishSignIn() {
        let app = launch("en")
        let signIn = app.buttons["sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        signIn.click()
        XCTAssertTrue(identity(app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["section-home"].exists)
    }

    @MainActor
    func testArabicSignedIn() {
        let app = launch("ar", signedIn: true)
        let card = identity(app)
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        // The Arabic section name, wherever the window shows it (sidebar row or header title).
        let dashboard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "لوحة التحكم", "لوحة التحكم")).firstMatch
        XCTAssertTrue(dashboard.waitForExistence(timeout: 10))
    }

    /// Off, unconfigured or not-in-tier features have no section (owner rule 2026-11-16).
    @MainActor
    func testUploadSectionFollowsTheFeature() {
        let on = launch("en", signedIn: true)
        XCTAssertTrue(on.descendants(matching: .any)["section-upload"].waitForExistence(timeout: 30))
        on.terminate()
        let off = launch("ar", signedIn: true, state: "invitation")
        XCTAssertTrue(off.descendants(matching: .any)["section-content"].waitForExistence(timeout: 30))
        XCTAssertFalse(off.descendants(matching: .any)["section-upload"].exists)
        off.terminate()
        let switchedOff = launch("en", signedIn: true, featuresOff: "upload")
        XCTAssertTrue(switchedOff.descendants(matching: .any)["section-content"].waitForExistence(timeout: 30))
        XCTAssertFalse(switchedOff.descendants(matching: .any)["section-upload"].exists)
    }

    /// Analytics answering 404 `feature_off` takes its section away without a message, before anyone opens it.
    @MainActor
    func testAnalyticsOffHidesItsSection() {
        let app = launch("en", signedIn: true, featuresOff: "analytics")
        XCTAssertTrue(app.descendants(matching: .any)["section-home"].waitForExistence(timeout: 30))
        let analytics = app.descendants(matching: .any)["section-analytics"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: analytics)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.descendants(matching: .any)["section-content"].exists)
        // No hollow Dashboard: its sections stay without Analytics.
        for section in ["dashboard-recent", "dashboard-held", "dashboard-queue"] {
            XCTAssertTrue(app.descendants(matching: .any)[section].waitForExistence(timeout: 15), section)
        }
    }

    @MainActor
    func testSignOutAsksFirst() {
        let app = launch("en", signedIn: true)
        let account = identity(app)
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.click()
        // macOS 27 menus drop SwiftUI accessibility identifiers on their items: fall back to the item's title.
        let manage = app.descendants(matching: .any)["accounts-manage"].firstMatch
        (manage.waitForExistence(timeout: 2) ? manage : app.menuItems["Accounts"].firstMatch).click()
        let signOut = app.buttons["account-sign-out-fixture-creator"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        signOut.click()
        XCTAssertTrue(app.buttons["confirm-cancel"].waitForExistence(timeout: 10))
        app.buttons["confirm-action"].click()
        XCTAssertTrue(app.buttons["sign-in"].waitForExistence(timeout: 20))
    }

    @MainActor
    func testContentAndRecentlyDeleted() {
        let app = launch("en", signedIn: true)
        let content = app.descendants(matching: .any)["section-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 30))
        content.click()
        let row = app.descendants(matching: .any).matching(identifier: "video-fixture-content-1").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["bulk-bar"].waitForExistence(timeout: 10))
        app.buttons["bulk-delete"].click()
        XCTAssertTrue(app.buttons["confirm-cancel"].waitForExistence(timeout: 10))
        app.buttons["confirm-action"].click()
        app.descendants(matching: .any)["section-deleted"].click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "deleted-fixture-content-1").firstMatch
                .waitForExistence(timeout: 20))
    }
}

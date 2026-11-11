import XCTest

/// Studio for Mac on fixtures: sign-in, channel picker and sign-out, in English and Arabic.
final class StudioSmokeTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String, signedIn: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", signedIn ? "YES" : "NO", "-AUNLanguage", language,
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func channelCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "channel-card").firstMatch
    }

    @MainActor
    func testEnglishSignIn() {
        let app = launch("en")
        let signIn = app.buttons["sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        signIn.click()
        XCTAssertTrue(channelCard(app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["section-home"].exists)
    }

    @MainActor
    func testArabicSignedIn() {
        let app = launch("ar", signedIn: true)
        let card = channelCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["لوحة التحكم"].firstMatch.exists)
    }

    @MainActor
    func testSignOutAsksFirst() {
        let app = launch("en", signedIn: true)
        let account = app.buttons["account-button"]
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.click()
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

import XCTest

/// Studio flows on fixtures: no network, English and Arabic.
final class StudioSignInTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String, signedIn: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", signedIn ? "YES" : "NO", "-AUNLanguage", language,
            "-AUNTheme", "dark", "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func channelCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "channel-card").firstMatch
    }

    @MainActor
    func testSignInShowsTheMainChannel() {
        let app = launch("en")
        let signIn = app.buttons["sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Sign in to Studio"].exists)
        signIn.tap()
        let card = channelCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(card.label.hasPrefix("Al Ummah Now"), card.label)
    }

    @MainActor
    func testChannelPickerListsOnlyChannelsYouCanUploadTo() {
        let app = launch("en", signedIn: true)
        let picker = app.buttons["channel-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 30))
        picker.tap()
        let editor = app.buttons["Tafsir Circle · Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Comments desk · Moderator"].exists)
        editor.tap()
        let card = channelCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.hasPrefix("Tafsir Circle"), card.label)
    }

    @MainActor
    func testArabicIsRightToLeft() {
        let app = launch("ar", signedIn: true)
        let card = channelCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertTrue(card.label.hasPrefix("الأمة الآن"), card.label)
        XCTAssertTrue(card.label.contains("مالك"), card.label)
        // The picker reads from the trailing edge in Arabic: the account button sits on the left.
        let account = app.buttons["account-button"]
        XCTAssertLessThan(account.frame.midX, app.windows.firstMatch.frame.midX)
    }

    @MainActor
    func testSignOutExplainsAndFocusesCancel() {
        let app = launch("en", signedIn: true)
        let account = app.buttons["account-button"]
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.tap()
        let signOut = app.buttons["account-sign-out-fixture-creator"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        signOut.tap()
        XCTAssertTrue(app.buttons["confirm-cancel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sign out of Fixture Creator?"].exists)
        app.buttons["confirm-cancel"].tap()
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        signOut.tap()
        app.buttons["confirm-action"].tap()
        XCTAssertTrue(app.buttons["sign-in"].waitForExistence(timeout: 20))
    }

    @MainActor
    func testAddSecondAccountAndSwitchBack() {
        let app = launch("ar", signedIn: true)
        let account = app.buttons["account-button"]
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.tap()
        app.buttons["account-add"].tap()
        XCTAssertTrue(channelCard(app).waitForExistence(timeout: 20))
        account.tap()
        let first = app.buttons["account-fixture-creator"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["account-fixture-account-1"].exists)
        first.tap()
        app.buttons["accounts-done"].tap()
        XCTAssertTrue(channelCard(app).waitForExistence(timeout: 10))
    }
}

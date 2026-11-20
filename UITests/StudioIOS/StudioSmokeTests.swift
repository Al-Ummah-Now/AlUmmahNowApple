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

    /// The identity menu: its value is "channel · role · account", each part direction-isolated.
    @MainActor
    private func identity(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "account-button").firstMatch
    }

    @MainActor
    func testSignInShowsTheMainChannel() {
        let app = launch("en")
        let signIn = app.buttons["sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Sign in to Studio"].exists)
        signIn.tap()
        let card = identity(app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue((card.value as? String ?? "").contains("Al Ummah Now"), card.debugDescription)
    }

    @MainActor
    func testChannelPickerListsOnlyChannelsYouCanUploadTo() {
        let app = launch("en", signedIn: true)
        let picker = identity(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 30))
        picker.tap()
        // Names and roles are direction-isolated in the label, so match the parts.
        func channel(_ name: String, _ role: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", name, role)).firstMatch
        }
        let editor = channel("Tafsir Circle", "Editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertFalse(channel("Comments desk", "Moderator").exists)
        editor.tap()
        let card = identity(app)
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let switched = NSPredicate(format: "value CONTAINS %@", "Tafsir Circle")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: switched, evaluatedWith: card)], timeout: 10), .completed)
    }

    @MainActor
    func testArabicIsRightToLeft() {
        let app = launch("ar", signedIn: true)
        let account = identity(app)
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        let value = account.value as? String ?? ""
        XCTAssertTrue(value.contains("الأمة الآن"), value)
        XCTAssertTrue(value.contains("مالك"), value)
        // The identity menu sits at the trailing edge: on the left in Arabic.
        XCTAssertLessThan(account.frame.midX, app.windows.firstMatch.frame.midX)
    }

    @MainActor
    func testSignOutExplainsAndFocusesCancel() {
        let app = launch("en", signedIn: true)
        let account = identity(app)
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.tap()
        app.accountsMenuItem.tap()
        let signOut = app.buttons["account-sign-out-fixture-creator"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        signOut.tap()
        XCTAssertTrue(app.buttons["confirm-cancel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sign out of Yusuf Rahman?"].exists)
        app.buttons["confirm-cancel"].tap()
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        signOut.tap()
        app.buttons["confirm-action"].tap()
        XCTAssertTrue(app.buttons["sign-in"].waitForExistence(timeout: 20))
    }

    @MainActor
    func testAddSecondAccountAndSwitchBack() {
        let app = launch("ar", signedIn: true)
        let account = identity(app)
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.tap()
        app.accountsMenuItem.tap()
        app.buttons["account-add"].tap()
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.tap()
        app.accountsMenuItem.tap()
        let first = app.buttons["account-fixture-creator"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["account-fixture-account-1"].exists)
        first.tap()
        app.buttons["accounts-done"].tap()
        XCTAssertTrue(account.waitForExistence(timeout: 10))
    }
}

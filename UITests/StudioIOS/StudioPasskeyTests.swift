import XCTest

/// Native passkey sign-in and "Add a passkey" on fixtures. The system passkey sheet cannot be driven in the simulator,
/// so the fixture ceremony builds the real requests and answers in its place (`-AUNFixturePasskey`).
final class StudioPasskeyTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String = "en", signedIn: Bool = false, passkey: String = "success")
        -> XCUIApplication
    {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", signedIn ? "YES" : "NO", "-AUNLanguage", language,
            "-AUNTheme", "dark", "-AUNFixturePasskey", passkey, "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func channelCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "channel-card").firstMatch
    }

    @MainActor
    private func dialogMessage(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "passkey-dialog-message").firstMatch
    }

    @MainActor
    func testBothWaysToSignInAreOffered() {
        let app = launch()
        let passkey = app.buttons["sign-in-passkey"]
        XCTAssertTrue(passkey.waitForExistence(timeout: 30))
        XCTAssertEqual(passkey.label, "Sign in with a passkey")
        let another = app.buttons["sign-in"]
        XCTAssertEqual(another.label, "Sign in another way")
        XCTAssertLessThan(passkey.frame.midY, another.frame.midY)
        XCTAssertTrue(
            app.staticTexts[
                "Sign in without a password, using a passkey saved on this device, in your password manager, on your phone or on a security key."
            ].exists)
    }

    @MainActor
    func testSignInWithAPasskey() {
        let app = launch()
        let passkey = app.buttons["sign-in-passkey"]
        XCTAssertTrue(passkey.waitForExistence(timeout: 30))
        passkey.tap()
        XCTAssertTrue(channelCard(app).waitForExistence(timeout: 20))
    }

    @MainActor
    func testClosingThePasskeySheetShowsNothing() {
        let app = launch(passkey: "cancel")
        let passkey = app.buttons["sign-in-passkey"]
        XCTAssertTrue(passkey.waitForExistence(timeout: 30))
        passkey.tap()
        XCTAssertTrue(passkey.waitForExistence(timeout: 10))
        XCTAssertFalse(dialogMessage(app).exists)
        XCTAssertFalse(app.descendants(matching: .any)["notice"].exists)
    }

    @MainActor
    func testNoPasskeyForTheAccountOffersAnotherWay() {
        let app = launch(passkey: "noCredential")
        let passkey = app.buttons["sign-in-passkey"]
        XCTAssertTrue(passkey.waitForExistence(timeout: 30))
        passkey.tap()
        XCTAssertTrue(dialogMessage(app).waitForExistence(timeout: 10))
        XCTAssertTrue(dialogMessage(app).label.hasPrefix("We couldn't find an account for this passkey"))
        let another = app.buttons["passkey-dialog-action"]
        XCTAssertEqual(another.label, "Sign in another way")
        another.tap()
        XCTAssertTrue(channelCard(app).waitForExistence(timeout: 20))
    }

    @MainActor
    func testArabicSignInIsRightToLeft() {
        let app = launch("ar")
        let passkey = app.buttons["sign-in-passkey"]
        XCTAssertTrue(passkey.waitForExistence(timeout: 30))
        XCTAssertEqual(passkey.label, "الدخول بمفتاح المرور")
        XCTAssertEqual(app.buttons["sign-in"].label, "تسجيل الدخول بطريقة أخرى")
        passkey.tap()
        let card = channelCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(card.label.hasPrefix("الأمة الآن"), card.label)
    }

    @MainActor
    func testAddAPasskeyFromAccounts() {
        let app = launch(signedIn: true)
        let account = app.buttons["account-button"]
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.tap()
        let add = app.buttons["account-add-passkey"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(dialogMessage(app).waitForExistence(timeout: 10))
        XCTAssertTrue(dialogMessage(app).label.hasPrefix("Passkey added."), dialogMessage(app).label)
        app.buttons["passkey-dialog-dismiss"].tap()
        XCTAssertTrue(app.buttons["accounts-done"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAnOldSignInSignsInAgainThenAddsThePasskey() {
        let app = launch("ar", signedIn: true, passkey: "stepUp")
        let account = app.buttons["account-button"]
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.tap()
        let add = app.buttons["account-add-passkey"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(dialogMessage(app).waitForExistence(timeout: 10))
        XCTAssertTrue(dialogMessage(app).label.hasPrefix("لحماية حسابك"), dialogMessage(app).label)
        let again = app.buttons["passkey-dialog-action"]
        XCTAssertEqual(again.label, "تسجيل الدخول مرة أخرى")
        again.tap()
        let added = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "أُضيف مفتاح المرور")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 15))
    }
}

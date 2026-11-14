import XCTest

/// Native passkey sign-in and "Add a passkey" in the Admin app, on fixtures. The system passkey sheet cannot be
/// driven in the simulator, so the fixture ceremony builds the real requests and answers (`-AUNFixturePasskey`).
final class AdminPasskeyTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    override func tearDown() async throws {
        await MainActor.run {
            let app = XCUIApplication()
            if app.state != .notRunning {
                app.terminate()
                _ = app.wait(for: .notRunning, timeout: 30)
            }
        }
        try await super.tearDown()
    }

    @MainActor
    private func launch(_ language: String = "en", signedIn: Bool = false, passkey: String = "success")
        -> XCUIApplication
    {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", signedIn ? "YES" : "NO", "-AUNFixtureRole", "reviewer",
            "-AUNLanguage", language, "-AUNTheme", "dark", "-AUNFixturePasskey", passkey,
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func firstRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "queue-row-fx-risk").firstMatch
    }

    @MainActor
    func testSignInWithAPasskeyOrAnotherWay() {
        let app = launch()
        let passkey = app.buttons["sign-in-passkey"]
        XCTAssertTrue(passkey.waitForExistence(timeout: 30))
        XCTAssertEqual(passkey.label, "Sign in with a passkey")
        XCTAssertEqual(app.buttons["sign-in"].label, "Sign in another way")
        passkey.tap()
        XCTAssertTrue(firstRow(app).waitForExistence(timeout: 30))
    }

    @MainActor
    func testNoPasskeyForTheAccountOffersAnotherWayInArabic() {
        let app = launch("ar", passkey: "noCredential")
        let passkey = app.buttons["sign-in-passkey"]
        XCTAssertTrue(passkey.waitForExistence(timeout: 30))
        XCTAssertEqual(passkey.label, "الدخول بمفتاح المرور")
        passkey.tap()
        let another = app.buttons["passkey-dialog-action"]
        XCTAssertTrue(another.waitForExistence(timeout: 10))
        XCTAssertEqual(another.label, "تسجيل الدخول بطريقة أخرى")
        another.tap()
        XCTAssertTrue(firstRow(app).waitForExistence(timeout: 30))
    }

    @MainActor
    func testClosingThePasskeySheetShowsNothing() {
        let app = launch(passkey: "cancel")
        let passkey = app.buttons["sign-in-passkey"]
        XCTAssertTrue(passkey.waitForExistence(timeout: 30))
        passkey.tap()
        XCTAssertTrue(passkey.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["passkey-dialog-dismiss"].exists)
        XCTAssertFalse(app.staticTexts["notice"].exists)
    }

    @MainActor
    func testAddAPasskeyFromTheAccountMenu() {
        let app = launch(signedIn: true, passkey: "stepUp")
        XCTAssertTrue(firstRow(app).waitForExistence(timeout: 30))
        app.buttons["account-menu"].tap()
        let add = app.buttons["account-add-passkey"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        // Signed in at launch long ago (fixture): sign in again first, then the passkey is added.
        let again = app.buttons["passkey-dialog-action"]
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        XCTAssertEqual(again.label, "Sign in again")
        again.tap()
        let added = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Passkey added.")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 15))
    }
}

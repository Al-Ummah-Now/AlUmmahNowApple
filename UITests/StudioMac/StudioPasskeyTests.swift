import XCTest

/// Native passkey sign-in on the Mac, on fixtures (the system sheet is answered by the fixture ceremony).
final class StudioPasskeyTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String = "en", passkey: String = "success") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "NO", "-AUNLanguage", language,
            "-AUNFixturePasskey", passkey, "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    func testSignInWithAPasskeyOrAnotherWay() {
        let app = launch()
        let passkey = app.buttons["sign-in-passkey"]
        XCTAssertTrue(passkey.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["sign-in"].exists)
        passkey.click()
        let card = app.descendants(matching: .any).matching(identifier: "channel-card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
    }

    @MainActor
    func testNoPasskeyForTheAccountOffersAnotherWay() {
        let app = launch("ar", passkey: "noCredential")
        let passkey = app.buttons["sign-in-passkey"]
        XCTAssertTrue(passkey.waitForExistence(timeout: 30))
        passkey.click()
        let another = app.buttons["passkey-dialog-action"]
        XCTAssertTrue(another.waitForExistence(timeout: 10))
        another.click()
        let card = app.descendants(matching: .any).matching(identifier: "channel-card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
    }
}

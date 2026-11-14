import XCTest

/// Native passkey sign-in in the Admin app on the Mac, on fixtures.
final class AdminPasskeyTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testSignInWithAPasskey() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "NO", "-AUNFixtureRole", "reviewer", "-AUNLanguage", "en",
            "-AUNTheme", "light", "-AUNFixturePasskey", "success", "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        let passkey = app.buttons["sign-in-passkey"]
        XCTAssertTrue(passkey.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["sign-in"].exists)
        passkey.click()
        let row = app.descendants(matching: .any).matching(identifier: "queue-row-fx-risk").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
    }
}

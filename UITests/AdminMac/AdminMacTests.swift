import XCTest

/// The Admin app on the Mac, on fixtures: split view, keyboard decisions, undo, Arabic.
final class AdminMacTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNFixtureRole", "reviewer", "-AUNLanguage",
            language, "-AUNTheme", "light", "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "queue-row-\(id)").firstMatch
    }

    @MainActor
    func testApproveWithTheKeyboardThenUndo() {
        let app = launch()
        let item = row(app, "fx-risk")
        XCTAssertTrue(item.waitForExistence(timeout: 30))
        item.click()
        XCTAssertTrue(app.buttons["approve"].waitForExistence(timeout: 15))
        app.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["toast-action"].waitForExistence(timeout: 10))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Reversed. The creator is told."].waitForExistence(timeout: 10))
    }

    @MainActor
    func testArabicQueue() {
        let app = launch("ar")
        XCTAssertTrue(row(app, "fx-risk").waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["بحاجة إلى إجراء"].firstMatch.exists)
    }
}

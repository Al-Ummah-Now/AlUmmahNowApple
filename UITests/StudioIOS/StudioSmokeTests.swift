import XCTest

final class StudioSmokeTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AUNLanguage", language, "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    @MainActor
    func testEnglish() {
        let app = launch("en")
        XCTAssertTrue(app.staticTexts["Editor"].firstMatch.waitForExistence(timeout: 30))
    }

    @MainActor
    func testArabic() {
        let app = launch("ar")
        XCTAssertTrue(app.staticTexts["المحرر"].firstMatch.waitForExistence(timeout: 30))
    }
}

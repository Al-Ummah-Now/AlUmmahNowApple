import XCTest

final class DiagnosticsSnapshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testEnglishLight() throws { try capture("en", "light") }

    @MainActor
    func testEnglishDark() throws { try capture("en", "dark") }

    @MainActor
    func testArabicLight() throws { try capture("ar", "light") }

    @MainActor
    func testArabicDark() throws { try capture("ar", "dark") }

    @MainActor
    private func capture(_ language: String, _ theme: String) throws {
        let app = try DiagnosticsSnapshot.launch(language, theme)
        let menu = app.descendants(matching: .any).matching(identifier: "account-button").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        let accounts = app.accountsMenuItem
        XCTAssertTrue(accounts.waitForExistence(timeout: 10))
        accounts.tap()

        let diagnostics = DiagnosticsSnapshot.control(app, identifier: "accounts-diagnostics", language: language)
        let form = app.collectionViews.firstMatch
        for _ in 0..<3 where !(diagnostics.exists && diagnostics.isHittable) { form.swipeUp() }
        DiagnosticsSnapshot.capture(diagnostics, app: app, language: language, theme: theme, test: self)
    }
}

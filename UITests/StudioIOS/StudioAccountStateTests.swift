import XCTest

/// Account states from `GET /api/me/creator` and the server's refusals, on fixtures. English and Arabic.
final class StudioAccountStateTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String, state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNFixtureAccountState", state,
            "-AUNLanguage", language, "-AUNTheme", "dark", "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func openTab(_ app: XCUIApplication, _ name: String) {
        let bar = app.tabBars.buttons[name]
        let button = bar.waitForExistence(timeout: 15) ? bar : app.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
    }

    @MainActor
    func testPendingDeletionShowsOneBannerAndNoUploader() {
        let app = launch("en", state: "pendingDeletion")
        let banner = app.descendants(matching: .any)["account-state"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        // The banner reads as one element: its title, then the message.
        XCTAssertTrue(banner.label.contains("Your videos account is scheduled for deletion. Contact support."))
        openTab(app, "Upload")
        XCTAssertTrue(app.descendants(matching: .any)["upload-refused"].firstMatch.waitForExistence(timeout: 10))
        keep("pending-deletion-en")
    }

    @MainActor
    func testPendingDeletionInArabic() {
        let app = launch("ar", state: "pendingDeletion")
        let banner = app.descendants(matching: .any)["account-state"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        XCTAssertTrue(banner.label.contains("حسابك في الفيديوهات مجدول للحذف. تواصل مع الدعم."))
        keep("pending-deletion-ar")
    }

    @MainActor
    func testNoCreatorTierSaysUploadsAreByInvitation() {
        let app = launch("en", state: "invitation")
        openTab(app, "Upload")
        XCTAssertTrue(app.descendants(matching: .any)["upload-refused"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["account-state"].firstMatch.exists)
        keep("invitation-en")
    }
}

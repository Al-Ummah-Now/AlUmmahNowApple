import XCTest

/// Admin app flows on fixtures: no network, no pushes, no AI. English and Arabic.
final class AdminFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(
        _ language: String = "en", signedIn: Bool = true, role: String = "reviewer", extra: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", signedIn ? "YES" : "NO", "-AUNFixtureRole", role,
                "-AUNLanguage", language, "-AUNTheme", "dark", "-ApplePersistenceIgnoreState", "YES",
            ] + extra
        app.launch()
        return app
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "queue-row-\(id)").firstMatch
    }

    @MainActor
    private func open(_ app: XCUIApplication, _ id: String) {
        let item = row(app, id)
        XCTAssertTrue(item.waitForExistence(timeout: 30), "row \(id)")
        item.tap()
        XCTAssertTrue(app.buttons["approve"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testSignInShowsTheQueueSortedByDeadline() {
        let app = launch(signedIn: false)
        let signIn = app.buttons["sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Sign in to review"].exists)
        signIn.tap()
        let first = row(app, "fx-nsfw")
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        let later = row(app, "fx-risk")
        XCTAssertTrue(later.exists)
        XCTAssertLessThan(first.frame.minY, later.frame.minY, "3 min left comes before 12 min left")
        XCTAssertTrue(first.label.contains("3 min left"), first.label)
    }

    @MainActor
    func testOpeningSignedInAsksForTheDeviceUnlockFirst() {
        let app = launch()
        // The fixture unlock answers at once; the queue only shows after it.
        XCTAssertTrue(row(app, "fx-risk").waitForExistence(timeout: 30))
    }

    @MainActor
    func testWithoutAPasscodeSignInIsRefused() {
        let app = launch(signedIn: false, extra: ["-AUNFixtureNoPasscode", "YES"])
        let signIn = app.buttons["sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        signIn.tap()
        let notice = app.staticTexts["notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("passcode"), notice.label)
    }

    @MainActor
    func testSomeoneWithoutAStaffRoleIsTurnedAway() {
        let app = launch(role: "viewer")
        XCTAssertTrue(app.staticTexts["This app is for Al Ummah Now staff"].waitForExistence(timeout: 30))
        let signOut = app.buttons["sign-out"]
        XCTAssertTrue(signOut.exists)
        signOut.tap()
        XCTAssertTrue(app.buttons["sign-in"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testApproveTakesEffectAndUndoReversesIt() {
        let app = launch()
        open(app, "fx-risk")
        app.buttons["approve"].tap()
        let undo = app.buttons["toast-action"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Approved “Charity drive update”"].exists)
        XCTAssertTrue(app.staticTexts["decided"].waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(app.staticTexts["Reversed. The creator is told."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["approve"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testRejectNeedsAReason() {
        let app = launch()
        open(app, "fx-risk")
        app.buttons["reject"].tap()
        let send = app.buttons["sheet-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertFalse(send.isEnabled)
        app.buttons["reason-spam_scam"].tap()
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.staticTexts["Rejected “Charity drive update”"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAConflictSaysWhoDecidedFirst() {
        let app = launch()
        open(app, "fx-conflict")
        app.buttons["approve"].tap()
        let message = app.staticTexts["decision-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.hasPrefix("Already approved by Amina"), message.label)
    }

    @MainActor
    func testNSFWIsBlurredUntilShowAndShowIsUndone() {
        let app = launch()
        open(app, "fx-nsfw")
        let reveal = app.buttons["reveal"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Blurred: flagged as sensitive."].exists)
        reveal.tap()
        let hide = app.buttons["hide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 10))
        hide.tap()
        XCTAssertTrue(app.buttons["reveal"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOfflineTheListShowsAndDecisionsAreOff() {
        let app = launch(extra: ["-AUNFixtureOffline", "YES"])
        XCTAssertTrue(app.descendants(matching: .any)["offline"].waitForExistence(timeout: 30))
        open(app, "fx-risk")
        XCTAssertTrue(app.descendants(matching: .any)["offline-decide"].exists)
        XCTAssertFalse(app.buttons["approve"].isEnabled)
    }

    @MainActor
    func testSeniorsSeeEscalationsFirst() {
        let app = launch(role: "senior")
        let minor = row(app, "fx-minor")
        XCTAssertTrue(minor.waitForExistence(timeout: 30))
        XCTAssertLessThan(minor.frame.minY, row(app, "fx-nsfw").frame.minY)
    }

    @MainActor
    func testReviewersNeverGetMinorItems() {
        let app = launch()
        XCTAssertTrue(row(app, "fx-nsfw").waitForExistence(timeout: 30))
        XCTAssertFalse(row(app, "fx-minor").exists)
    }

    @MainActor
    func testArabicIsRightToLeftAndSaysMarai() {
        let app = launch("ar")
        let item = row(app, "fx-risk")
        XCTAssertTrue(item.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["بحاجة إلى إجراء"].exists)
        // The account menu sits on the trailing edge: the left in Arabic.
        let account = app.buttons["account-menu"]
        XCTAssertTrue(account.exists)
        XCTAssertLessThan(account.frame.midX, app.windows.firstMatch.frame.midX)
        item.tap()
        let approve = app.buttons["approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 15))
        XCTAssertTrue(approve.label.contains("موافقة"), approve.label)
    }
}

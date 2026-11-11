import XCTest

/// Real sign-in against auth.qa through the system web authentication session.
///
/// Runs only when the runner has `AUN_LIVE_QA=1`, `AUN_QA_EMAIL` and `AUN_QA_PASSWORD` (pass them to xcodebuild
/// with the `TEST_RUNNER_` prefix). CI runs it in the `live-qa` job; it never runs in the hermetic jobs.
final class LiveQASignInTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testSignInThroughAuthAndSignOut() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AUN_LIVE_QA"] == "1", let email = env["AUN_QA_EMAIL"], let password = env["AUN_QA_PASSWORD"] else {
            throw XCTSkip("Set AUN_LIVE_QA=1, AUN_QA_EMAIL and AUN_QA_PASSWORD to run against QA.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AUNLanguage", "en", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        // A previous run may have left an account signed in.
        if app.buttons["account-button"].waitForExistence(timeout: 10) { signOutAll(app) }
        let signIn = app.buttons["sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        signIn.tap()

        let web = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let emailField = web.textFields["Email"]
        guard emailField.waitForExistence(timeout: 30) else {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("No Email field.\nSafariViewService: \(web.debugDescription)\nApp: \(app.debugDescription)")
            return
        }
        emailField.tap()
        // Return submits the form; the browser then focuses the empty required Password field, which avoids tapping
        // a secure field under the AutoFill bar.
        emailField.typeText(email + "\n")
        let passwordField = web.secureTextFields["Password"]
        XCTAssertTrue(passwordField.wait(for: \.hasFocus, toEqual: true, timeout: 10))
        web.typeText(password + "\n")

        let picker = app.buttons["channel-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 60))
        XCTAssertTrue(app.descendants(matching: .any)["channel-card"].waitForExistence(timeout: 30))
        keep("signed-in")
        picker.tap()
        keep("channel-picker")
        app.tap()
        signOutAll(app)
        XCTAssertTrue(app.buttons["sign-in"].waitForExistence(timeout: 30))
    }

    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func signOutAll(_ app: XCUIApplication) {
        while app.buttons["account-button"].waitForExistence(timeout: 5) {
            app.buttons["account-button"].tap()
            let signOut = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'account-sign-out-'")).firstMatch
            guard signOut.waitForExistence(timeout: 10) else { return }
            signOut.tap()
            app.buttons["confirm-action"].tap()
            _ = app.buttons["sign-in"].waitForExistence(timeout: 10)
        }
    }
}

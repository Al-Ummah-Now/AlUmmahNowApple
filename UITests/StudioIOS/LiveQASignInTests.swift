import XCTest

/// Real sign-in against auth.qa through the system web authentication session.
///
/// Runs only when the runner has `AUN_LIVE_QA=1`, `AUN_QA_EMAIL` and `AUN_QA_PASSWORD` (pass them to xcodebuild
/// with the `TEST_RUNNER_` prefix). CI runs it in the `live-qa` job; it never runs in the hermetic jobs.
class LiveQATestCase: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Launches the QA build signed in as the QA creator (signing in through auth.qa when needed).
    @MainActor
    func launchSignedIn(language: String = "en", extra: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard env["AUN_LIVE_QA"] == "1", let email = env["AUN_QA_EMAIL"], let password = env["AUN_QA_PASSWORD"] else {
            throw XCTSkip("Set AUN_LIVE_QA=1, AUN_QA_EMAIL and AUN_QA_PASSWORD to run against QA.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AUNLanguage", language, "-ApplePersistenceIgnoreState", "YES"] + extra
        app.launch()
        if app.buttons["account-button"].waitForExistence(timeout: 10) { return app }
        try signIn(app, email: email, password: password)
        return app
    }

    @MainActor
    func signIn(_ app: XCUIApplication, email: String, password: String) throws {

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

        XCTAssertTrue(app.buttons["channel-picker"].waitForExistence(timeout: 60))
    }

    @MainActor
    func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func signOutAll(_ app: XCUIApplication) {
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

final class LiveQASignInTests: LiveQATestCase {
    @MainActor
    func testSignInThroughAuthAndSignOut() throws {
        let app = try launchSignedIn()
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
}

final class LiveQAUploadTests: LiveQATestCase {
    /// The channel's real playlists load in the upload form, with no error, in both languages.
    @MainActor
    private func assertPlaylistsLoad(_ app: XCUIApplication, language: String) {
        let playlist = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'upload-playlist-'")).firstMatch
        var swipes = 0
        while !playlist.exists, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(playlist.waitForExistence(timeout: 20), "no playlist row")
        let error = language == "ar" ? "تعذّر" : "We couldn't load"
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", error)).count, 0)
        keep("upload-playlists-\(language)")
    }

    /// Uploads one generated private clip through the real TUS proxy to the creator's channel.
    @MainActor
    func testUploadOnePrivateClip() throws {
        let app = try launchSignedIn(extra: ["-AUNSampleVideos", "1"])
        app.tabBars.buttons["Upload"].tap()
        let pattern = app.textFields["upload-pattern"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 30))
        pattern.tap()
        pattern.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) { app.menuItems["Select All"].tap() }
        pattern.typeText("E2E Native upload {{date}} {{n}}\n")
        app.swipeUp()
        keep("upload-form-en")
        app.segmentedControls["upload-visibility"].buttons["Private"].tap()
        assertPlaylistsLoad(app, language: "en")
        let send = app.buttons["upload-send"]
        while !send.isHittable { app.swipeUp() }
        send.tap()
        let done = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "Uploaded. Processing starts on the server."))
        let failed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "upload stopped"))
        let deadline = Date().addingTimeInterval(240)
        while done.count < 1, failed.count < 1, Date() < deadline { sleep(2) }
        keep("upload-queue-en")
        XCTAssertEqual(done.count, 1)
    }

    /// The Arabic form against QA: right to left, playlists loaded. Nothing is uploaded.
    @MainActor
    func testArabicFormLoadsPlaylists() throws {
        let app = try launchSignedIn(language: "ar", extra: ["-AUNSampleVideos", "1"])
        app.tabBars.buttons["رفع"].tap()
        XCTAssertTrue(app.textFields["upload-pattern"].waitForExistence(timeout: 30))
        app.swipeUp()
        keep("upload-form-ar")
        assertPlaylistsLoad(app, language: "ar")
    }
}

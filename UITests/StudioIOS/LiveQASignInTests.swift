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

/// Manage against QA on the creator's own test uploads ("E2E Native …"): find them, bulk edit, delete, then
/// queue them for permanent deletion, which also cleans up after the upload test. Then analytics.
final class LiveQAManageTests: LiveQATestCase {
    private let marker = "E2E Native"

    @MainActor
    private func noLoadError(_ app: XCUIApplication) {
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "We couldn't load")).count, 0,
            "a load error is on screen")
    }

    @MainActor
    private func testRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'video-' AND label CONTAINS %@", marker))
    }

    /// Opens the status tab that holds this test's uploads; false when none appears within about three minutes
    /// (a fresh upload takes a moment to reach the channel's content index).
    @MainActor
    private func openTabWithTestUploads(_ app: XCUIApplication) -> Bool {
        let tabs = app.segmentedControls["content-status"].buttons
        XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 30))
        let deadline = Date().addingTimeInterval(180)
        repeat {
            for index in 0..<tabs.count {
                tabs.element(boundBy: index).tap()
                if testRows(app).firstMatch.waitForExistence(timeout: 6) { return true }
                noLoadError(app)
            }
        } while Date() < deadline
        return false
    }

    @MainActor
    func testManageTestUploadsAndAnalytics() throws {
        let app = try launchSignedIn()
        app.tabBars.buttons["Content"].tap()
        XCTAssertTrue(app.buttons["content-sort"].waitForExistence(timeout: 30))
        noLoadError(app)
        keep("content-live-en")

        guard openTabWithTestUploads(app) else {
            // Right after the upload test (ci.sh live-qa) the uploads must be there; on their own, skip.
            if ProcessInfo.processInfo.environment["AUN_EXPECT_TEST_UPLOADS"] == "1" {
                XCTFail("The upload test's \(marker) videos never appeared in the channel's content.")
                return
            }
            throw XCTSkip("No \(marker) uploads on QA; run LiveQAUploadTests first.")
        }
        // Search narrows the tab to this test's uploads (and shows live suggestions).
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 3) { app.swipeDown() }
        field.tap()
        field.typeText(marker)
        let suggestion = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'suggestion-' AND label CONTAINS %@", marker))
        XCTAssertTrue(suggestion.firstMatch.waitForExistence(timeout: 20), "no live suggestion")
        keep("search-live-en")
        // Submitting closes the suggestions and shows the filtered list.
        app.keyboards.buttons["search"].firstMatch.tap()
        XCTAssertTrue(testRows(app).firstMatch.waitForExistence(timeout: 20))
        let count = testRows(app).count

        // Bulk edit: tag them.
        app.buttons["content-select"].tap()
        for index in 0..<count { testRows(app).element(boundBy: index).tap() }
        app.buttons["bulk-edit"].tap()
        let addTags = app.textFields["bulk-add-tags"]
        XCTAssertTrue(addTags.waitForExistence(timeout: 10))
        addTags.tap()
        addTags.typeText("e2e-native")
        keep("bulk-edit-live-en")
        app.buttons["bulk-apply"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "updated")).firstMatch
                .waitForExistence(timeout: 30))

        // Soft delete.
        if !app.buttons["bulk-delete"].exists {
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
            app.buttons["content-select"].tap()
        }
        for index in 0..<testRows(app).count { testRows(app).element(boundBy: index).tap() }
        app.buttons["bulk-delete"].tap()
        XCTAssertTrue(app.buttons["confirm-cancel"].waitForExistence(timeout: 10))
        app.buttons["confirm-action"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Restore from Recently deleted"))
                .firstMatch.waitForExistence(timeout: 30))

        // Recently deleted: queue them for permanent deletion (cleanup).
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        app.buttons["open-deleted"].tap()
        let deleted = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'deleted-' AND label CONTAINS %@", marker))
        XCTAssertTrue(deleted.firstMatch.waitForExistence(timeout: 30))
        noLoadError(app)
        keep("recently-deleted-live-en")
        for index in 0..<deleted.count { deleted.element(boundBy: index).tap() }
        app.buttons["deleted-purge"].tap()
        XCTAssertTrue(app.buttons["confirm-cancel"].waitForExistence(timeout: 10))
        app.buttons["confirm-action"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "queued for permanent deletion"))
                .firstMatch.waitForExistence(timeout: 30))
        keep("purged-live-en")

        app.tabBars.buttons["Analytics"].tap()
        XCTAssertTrue(app.segmentedControls["analytics-range"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Top videos"].waitForExistence(timeout: 30))
        noLoadError(app)
        keep("analytics-live-en")
    }
}

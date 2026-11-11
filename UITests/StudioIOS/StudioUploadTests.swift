import XCTest

/// Upload on fixtures: two generated clips, values set for all, the queue to the end.
final class StudioUploadTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNSampleVideos", "2", "-AUNLanguage", language,
            "-AUNTheme", "dark", "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func openUpload(_ app: XCUIApplication, tab: String) {
        // iPhone has a bottom tab bar; iPadOS draws the tabs at the top, outside `tabBars`.
        let bar = app.tabBars.buttons[tab]
        let button = bar.waitForExistence(timeout: 15) ? bar : app.buttons[tab].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
    }

    @MainActor
    func testBatchUploadWithValuesForAll() {
        let app = launch("en")
        openUpload(app, tab: "Upload")
        let pattern = app.textFields["upload-pattern"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 30))
        // The pattern starts as {{filename}}: replace it.
        pattern.tap()
        pattern.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) { app.menuItems["Select All"].tap() }
        pattern.typeText("Lesson {{episode}}")
        XCTAssertEqual(app.textFields["upload-title-1"].placeholderValue, "Lesson 2")

        app.swipeUp()
        let playlist = app.switches["upload-playlist-fixture-playlist-1"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 10))
        playlist.firstMatch.tap()

        let send = app.buttons["upload-send"]
        while !send.isHittable { app.swipeUp() }
        XCTAssertEqual(send.label, "Start upload (2)")
        keep("upload-form-en")
        send.tap()

        let second = app.descendants(matching: .any)["upload-job-1"]
        XCTAssertTrue(second.waitForExistence(timeout: 20))
        let done = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "Uploaded. Processing starts on the server."))
        let deadline = Date().addingTimeInterval(60)
        while done.count < 2, Date() < deadline { sleep(1) }
        XCTAssertEqual(done.count, 2)
        keep("upload-done-en")
        XCTAssertTrue(app.staticTexts["Lesson 1"].firstMatch.exists)
    }

    @MainActor
    func testArabicUploadFormIsRightToLeft() {
        let app = launch("ar")
        openUpload(app, tab: "رفع")
        let send = app.buttons["upload-send"]
        while !send.waitForExistence(timeout: 2) || !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.label.hasPrefix("بدء الرفع ("), send.label)
        XCTAssertTrue(send.label.contains("2"), send.label)
        keep("upload-form-ar")
        let photos = app.buttons["upload-photos"]
        app.swipeDown()
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(photos.frame.midX, app.windows.firstMatch.frame.midX)
    }

    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

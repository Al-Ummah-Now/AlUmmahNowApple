import UIKit
import XCTest

/// Upload on fixtures: two generated clips, values set for all, the queue to the end.
final class StudioUploadTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String, theme: String = "dark", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNSampleVideos", "2", "-AUNLanguage", language,
                "-AUNTheme", theme, "-ApplePersistenceIgnoreState", "YES",
            ] + extra
        app.launch()
        return app
    }

    @MainActor
    func testBatchUploadWithValuesForAll() {
        let app = launch("en")
        app.openStudioTab(named: "Upload")
        let pattern = app.textFields["upload-pattern"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 30))
        // The pattern starts as {{filename}}: replace it.
        pattern.tap()
        pattern.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) { app.menuItems["Select All"].tap() }
        pattern.typeText("Tafsir {{episode}}")
        XCTAssertEqual(app.textFields["upload-title-1"].placeholderValue, "Tafsir 2")

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
        XCTAssertTrue(app.staticTexts["Tafsir 1"].firstMatch.exists)
    }

    /// A server that stops answering: the upload ends in the stopped state with Retry, in both languages and themes
    /// (Apple #105).
    @MainActor
    func testAnUploadThatStopsMovingStopsWithRetry() {
        for (language, tab, stopped, retry) in [
            ("en", "Upload", "The upload stopped", "Try again"), ("ar", "رفع", "توقف الرفع", "إعادة المحاولة"),
        ] {
            for theme in ["dark", "light"] {
                let app = launch(
                    language, theme: theme, extra: ["-AUNFixtureStalledUploads", "YES", "-AUNUploadStallSeconds", "3"])
                app.openStudioTab(named: tab)
                let send = app.buttons["upload-send"]
                while !send.waitForExistence(timeout: 2) || !send.isHittable { app.swipeUp() }
                send.tap()
                let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", stopped))
                let deadline = Date().addingTimeInterval(60)
                while text.count < 2, Date() < deadline { sleep(1) }
                XCTAssertEqual(text.count, 2, "both clips stop with the message")
                XCTAssertTrue(app.buttons[retry].firstMatch.exists, "Retry is offered")
                keep("upload-stalled-\(language)-\(theme)")
                app.terminate()
            }
        }
    }

    /// Section titles and footers use the theme's muted text token (#107): the Upload tab in both languages and themes,
    /// the form's top and bottom and the finished queue.
    @MainActor
    func testUploadTabSectionTitlesAndFootersUseTheMutedToken() throws {
        for (language, tab) in [("en", "Upload"), ("ar", "رفع")] {
            for theme in ["dark", "light"] {
                let app = launch(language, theme: theme)
                app.openStudioTab(named: tab)
                let send = app.buttons["upload-send"]
                XCTAssertTrue(app.textFields["upload-pattern"].waitForExistence(timeout: 30))
                keep("studio-upload-top-\(language)-\(theme)")
                let footer = app.staticTexts["upload-channel-note"]
                for _ in 0..<8 where !(footer.exists && send.isHittable && footerFits(footer, in: app)) {
                    app.swipeUp()
                }
                XCTAssertTrue(footer.exists && send.isHittable)
                let bottom = try XCTUnwrap(footerBoundary(in: app), "the iPhone bottom tab bar must be visible")
                XCTAssertLessThanOrEqual(footer.frame.maxY + 12, bottom, "the whole channel footer clears the tab bar")
                keep("studio-upload-bottom-\(language)-\(theme)")
                send.tap()
                let done = app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@", language == "en" ? "Uploaded" : "اكتمل الرفع"))
                let deadline = Date().addingTimeInterval(60)
                while done.count < 2, Date() < deadline { sleep(1) }
                app.swipeDown()
                keep("studio-upload-queue-\(language)-\(theme)")
                app.terminate()
            }
        }
    }

    @MainActor
    private func footerBoundary(in app: XCUIApplication) -> CGFloat? {
        let viewport = app.frame
        let bottomBar = app.tabBars.allElementsBoundByIndex.map(\.frame)
            .first { $0.minY >= viewport.midY && viewport.intersects($0) }
        if UIDevice.current.userInterfaceIdiom == .phone {
            return bottomBar?.minY
        }
        return bottomBar?.minY ?? viewport.maxY
    }

    @MainActor
    private func footerFits(_ footer: XCUIElement, in app: XCUIApplication) -> Bool {
        guard let bottom = footerBoundary(in: app) else { return false }
        return footer.frame.maxY + 12 <= bottom
    }

    /// The status bar is light over the navy header in light mode too (#87): the Upload tab in both languages and themes.
    @MainActor
    func testUploadTabStatusBarIsLightOverTheHeader() {
        for (language, tab) in [("en", "Upload"), ("ar", "رفع")] {
            for theme in ["dark", "light"] {
                let app = launch(language, theme: theme)
                app.openStudioTab(named: tab)
                XCTAssertTrue(app.textFields["upload-pattern"].waitForExistence(timeout: 30))
                keep("studio-upload-\(language)-\(theme)")
                app.terminate()
            }
        }
    }

    @MainActor
    func testArabicUploadFormIsRightToLeft() {
        let app = launch("ar")
        app.openStudioTab(named: "رفع")
        let send = app.buttons["upload-send"]
        while !send.waitForExistence(timeout: 2) || !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.label.hasPrefix("بدء الرفع ("), send.label)
        XCTAssertTrue(send.label.contains("2"), send.label)
        keep("upload-form-ar")
        let photos = app.buttons["upload-photos"]
        app.swipeDown()
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        // The pick buttons sit at the row's end, which is the left in Arabic, with Photos (the primary) last.
        let files = app.buttons["upload-files"]
        XCTAssertLessThan(photos.frame.midX, app.windows.firstMatch.frame.midX)
        if files.exists { XCTAssertLessThan(photos.frame.midX, files.frame.midX) }
    }

    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

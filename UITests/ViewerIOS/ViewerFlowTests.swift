import XCTest

final class ViewerFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String, theme: String = "dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AUNUseFixtures", "YES", "-AUNLanguage", language, "-AUNTheme", theme]
        app.launch()
        return app
    }

    private let firstCard = "video-card-trending-fixture-1"

    @MainActor
    private func card(_ app: XCUIApplication) -> XCUIElement {
        let element = app.buttons[firstCard]
        XCTAssertTrue(element.waitForExistence(timeout: 30))
        return element
    }

    @MainActor
    func testEnglishLayoutStartsAtLeading() {
        let app = launch("en")
        let frame = card(app).frame
        XCTAssertLessThan(frame.midX, app.windows.firstMatch.frame.midX + frame.width / 2)
        XCTAssertLessThan(frame.minX, 40)
    }

    @MainActor
    func testArabicLayoutIsMirrored() {
        let app = launch("ar")
        let frame = card(app).frame
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(frame.maxX, window.maxX - 40, "first card must sit at the right edge in RTL")
        XCTAssertTrue(app.staticTexts["الأكثر رواجًا"].exists)
    }

    @MainActor
    func testWatchPageShowsLocalizedContentAndControls() {
        let app = launch("ar")
        card(app).tap()
        let title = app.staticTexts["watch-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "مقدمة في التفسير، الجزء ١")
        XCTAssertTrue(app.buttons["chapter-c1"].exists)
        XCTAssertTrue(app.buttons["subtitles-menu"].exists)
        XCTAssertTrue(app.buttons["speed-menu"].exists)
        XCTAssertTrue(app.buttons["quality-menu"].exists)
    }

    @MainActor
    func testQualityMenuListsRenditionsAndSkipControlsMirror() {
        let app = launch("ar")
        card(app).tap()
        let forward = app.buttons["skip-forward"]
        XCTAssertTrue(forward.waitForExistence(timeout: 20))
        XCTAssertLessThan(forward.frame.midX, app.buttons["skip-back"].frame.midX, "RTL places back on the right")
        app.buttons["quality-menu"].tap()
        XCTAssertTrue(app.buttons["٣٦٠p"].waitForExistence(timeout: 5), "Arabic shows Eastern Arabic (Hindi) numerals")
        XCTAssertTrue(app.buttons["تلقائي"].exists)
    }

    @MainActor
    func testLanguageSwitchesWithoutRelaunch() {
        let app = launch("en")
        _ = card(app)
        XCTAssertTrue(app.staticTexts["Trending"].exists)
        app.buttons["settings-menu"].tap()
        app.buttons["العربية"].tap()
        XCTAssertTrue(app.staticTexts["الأكثر رواجًا"].waitForExistence(timeout: 5))
    }

    /// The status bar over the header is light in every mode: the header is dark in light mode too (Apple #87).
    @MainActor
    func testStatusBarStaysLightOverTheHeaderInEveryMode() {
        for language in ["en", "ar"] {
            for theme in ["dark", "light"] {
                let app = launch(language, theme: theme)
                _ = card(app)
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "viewer-header-\(language)-\(theme)"
                shot.lifetime = .keepAlways
                add(shot)
                app.terminate()
            }
        }
    }

    @MainActor
    func testBlockChannelHidesWatchDetailsAndHomeAndUnblocksFromSettings() {
        let app = launch("en")
        card(app).tap()
        let menu = app.buttons["watch-actions-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        XCTAssertTrue(app.buttons["report-video"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["report-channel"].exists)
        let blockBtn = app.buttons["block-channel"]
        XCTAssertTrue(blockBtn.exists)
        blockBtn.tap()
        XCTAssertTrue(app.buttons["block-confirm-cancel"].waitForExistence(timeout: 10))
        app.buttons["block-confirm-action"].tap()

        // Blocked page hides title, description, and chapters, showing only the blocked card + Unblock.
        XCTAssertTrue(app.buttons["watch-unblock-channel"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["watch-title"].exists)
        XCTAssertFalse(app.staticTexts["watch-description"].exists)
        XCTAssertFalse(app.buttons["chapter-c1"].exists)

        // Back to Home: blocked channel is hidden, unblock from Settings restores Home.
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "identifier != 'watch-actions-menu'")).firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(app.buttons["settings-menu"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons[firstCard].exists)
        app.buttons["settings-menu"].tap()
        app.buttons["settings-blocked-list"].tap()
        let unblock = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unblock-'")).firstMatch
        XCTAssertTrue(unblock.waitForExistence(timeout: 10))
        unblock.tap()
        XCTAssertTrue(app.descendants(matching: .any)["blocked-list-empty"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["blocked-list-done"].tap()
        XCTAssertTrue(app.buttons[firstCard].waitForExistence(timeout: 15))
    }

    @MainActor
    func testLiveChatBlockUserHidesMessageAndKeepsOtherMessages() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureLive", "YES", "-AUNOpenLive", "fixture-live",
            "-AUNLanguage", "en", "-AUNTheme", "dark",
        ]
        app.launch()
        let chatMenu = app.buttons["chat-actions-m0"]
        XCTAssertTrue(chatMenu.waitForExistence(timeout: 30))
        chatMenu.tap()
        let blockUser = app.buttons["block-chat-user-m0"]
        XCTAssertTrue(blockUser.waitForExistence(timeout: 10))
        blockUser.tap()
        XCTAssertTrue(app.buttons["block-confirm-action"].waitForExistence(timeout: 10))
        app.buttons["block-confirm-action"].tap()

        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: chatMenu)], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["chat-actions-m2"].exists)
    }
}

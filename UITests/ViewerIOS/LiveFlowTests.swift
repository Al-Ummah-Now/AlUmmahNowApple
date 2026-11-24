import XCTest

/// Live streams and premieres on fixtures (wiki E17). Off, the app is as it was.
final class LiveFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String, _ extra: [String] = ["-AUNFixtureLive", "YES"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AUNUseFixtures", "YES", "-AUNLanguage", language, "-AUNTheme", "dark"] + extra
        app.launch()
        return app
    }

    @MainActor
    func testNothingLiveShowsNoLiveRail() {
        let app = launch("en", [])
        XCTAssertTrue(app.buttons["video-card-trending-fixture-1"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["live-see-all"].exists)
    }

    @MainActor
    func testOpensALiveStreamFromHomeWithItsChat() {
        let app = launch("en")
        let card = app.buttons["live-card-fixture-live"]
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.tap()
        XCTAssertTrue(app.staticTexts["live-title"].waitForExistence(timeout: 20))
        let message = app.descendants(matching: .any)["live-chat-message-m4"]
        XCTAssertTrue(message.waitForExistence(timeout: 20))
        // Reading only: the viewer has no account to write with
        XCTAssertEqual(app.textFields.count, 0)
    }

    @MainActor
    func testFiltersByEventInArabic() {
        let app = launch("ar")
        let all = app.buttons["live-see-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 30))
        all.tap()
        let filter = app.buttons["live-event-menu"]
        XCTAssertTrue(filter.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["live-card-fixture-live"].waitForExistence(timeout: 10))
        filter.tap()
        let jumuah = app.buttons["الجمعة"].firstMatch
        XCTAssertTrue(jumuah.waitForExistence(timeout: 10))
        jumuah.tap()
        // The grid is lazy: filtered, the coming stream is the first on the screen
        XCTAssertTrue(app.buttons["live-card-fixture-coming"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["live-card-fixture-live"].exists)
    }

    @MainActor
    func testAPremiereCountsDownInArabicDigits() {
        let app = launch("ar", ["-AUNFixtureLive", "YES", "-AUNOpenLive", "fixture-premiere"])
        let countdown = app.staticTexts["live-countdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 30))
        XCTAssertNil(countdown.label.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")))
    }
}

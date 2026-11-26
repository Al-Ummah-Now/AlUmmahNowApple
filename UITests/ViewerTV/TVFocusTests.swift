import XCTest

final class TVFocusTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AUNUseFixtures", "YES", "-AUNLanguage", language]
        app.launch()
        return app
    }

    @MainActor
    private func waitForFocus(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let focused = NSPredicate(format: "hasFocus == true")
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: focused, object: element)], timeout: 15)
        XCTAssertEqual(result, .completed, "expected focus on \(element)", file: file, line: line)
    }

    /// The focus engine picks the card nearest the hero, so the test follows whichever card that is.
    @MainActor
    private func moveThroughRail(app: XCUIApplication, next: XCUIRemote.Button) {
        waitForFocus(app.buttons["hero"])
        XCUIRemote.shared.press(.down)
        let focused = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'video-card-trending-' AND hasFocus == true")
        )
        .firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 15))
        let index = Int(focused.identifier.split(separator: "-").last ?? "") ?? 0
        XCUIRemote.shared.press(next)
        waitForFocus(app.buttons["video-card-trending-fixture-\(index + 1)"])
    }

    @MainActor
    func testEnglishRailMovesRight() {
        moveThroughRail(app: launch("en"), next: .right)
    }

    @MainActor
    func testArabicRailMovesLeft() {
        let app = launch("ar")
        moveThroughRail(app: app, next: .left)
        XCTAssertTrue(app.staticTexts["الأكثر رواجًا"].exists)
    }

    @MainActor
    func testSelectOpensPlayer() {
        let app = launch("en")
        waitForFocus(app.buttons["hero"])
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.otherElements["player"].waitForExistence(timeout: 20))
    }

    /// The report page for `title`, its whole address, and everything inside the screen; Dismiss has the focus.
    @MainActor
    private func checkReportPage(
        _ app: XCUIApplication, title: String, address: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            app.descendants(matching: .any)["tv-report-sheet"].firstMatch.waitForExistence(timeout: 15), file: file, line: line)
        let heading = app.staticTexts["tv-report-title"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertEqual(heading.label, title, file: file, line: line)
        let body = app.staticTexts["tv-report-body"]
        XCTAssertFalse(body.label.contains("http"), file: file, line: line)
        let link = app.staticTexts["tv-report-address"]
        XCTAssertTrue(link.label.hasSuffix(address), "\(link.label) has no \(address)", file: file, line: line)
        let dismiss = app.buttons["tv-report-dismiss"]
        waitForFocus(dismiss, file: file, line: line)
        // Clear of the edges a television may crop, and of each other
        let screen = app.windows.firstMatch.frame.insetBy(dx: 60, dy: 60)
        for element in [app.images["tv-report-qr"], heading, body, link, dismiss] {
            XCTAssertTrue(element.exists, file: file, line: line)
            XCTAssertTrue(screen.contains(element.frame), "\(element.identifier) \(element.frame) is cut", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(heading.frame.maxY, body.frame.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(body.frame.maxY, link.frame.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(link.frame.maxY, dismiss.frame.minY, file: file, line: line)
    }

    @MainActor
    private func gone(_ element: XCUIElement) -> Bool {
        let missing = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: missing, object: element)], timeout: 15) == .completed
    }

    @MainActor
    func testTransportBarReportOpensQRCodePage() {
        for (language, title) in [("en", "Report video"), ("ar", "الإبلاغ عن المرئي")] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-AUNUseFixtures", "YES", "-AUNFixturePlayable", "YES", "-AUNLanguage", language,
                "-AUNOpenVideo", FixtureIDs.video,
            ]
            app.launch()
            XCTAssertTrue(app.otherElements["player"].waitForExistence(timeout: 30))
            let report = app.cells["tv-report-video"]
            if !report.exists { XCUIRemote.shared.press(.up) }
            XCTAssertTrue(report.waitForExistence(timeout: 20))
            for _ in 0..<2 where !report.hasFocus { XCUIRemote.shared.press(.up) }
            for _ in 0..<6 where !report.hasFocus { XCUIRemote.shared.press(.right) }
            for _ in 0..<8 where !report.hasFocus { XCUIRemote.shared.press(.left) }
            XCTAssertTrue(report.hasFocus)
            XCUIRemote.shared.press(.select)
            checkReportPage(app, title: title, address: "/\(language)/report?type=video&id=\(FixtureIDs.video)")
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(gone(app.buttons["tv-report-dismiss"]))
            XCTAssertTrue(app.otherElements["player"].waitForExistence(timeout: 15))
            app.terminate()
        }
    }

    @MainActor
    private func openLive(_ language: String, _ id: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureLive", "YES", "-AUNFixturePlayable", "YES", "-AUNOpenLive", id,
            "-AUNLanguage", language,
        ]
        app.launch()
        return app
    }

    @MainActor
    private func checkLiveTypography(
        language: String, title: String, chatTitle: String, description: String
    ) {
        let app = openLive(language, FixtureIDs.live)
        let heading = app.staticTexts["live-title"]
        let chatHeading = app.staticTexts["live-chat-title"]
        let hint = app.staticTexts["tv-report-chat-hint"]
        let metadata = app.staticTexts["live-metadata"]
        let summary = app.staticTexts["live-description"]
        let badge = app.staticTexts["live-tag-now"]
        let report = app.buttons["tv-report-stream"]

        XCTAssertTrue(hint.waitForExistence(timeout: 30))
        XCTAssertEqual(heading.label, title)
        XCTAssertEqual(chatHeading.label, chatTitle)
        XCTAssertEqual(summary.label, description)

        let screen = app.windows.firstMatch.frame
        for element in [heading, chatHeading, hint, metadata, summary, badge, report] {
            XCTAssertTrue(element.exists)
            XCTAssertTrue(screen.contains(element.frame), "\(element.identifier) outside \(screen): \(element.frame)")
        }
        let bodyMinimum: CGFloat = language == "ar" ? 26 : 24
        let heroMinimum: CGFloat = language == "ar" ? 50 : 48
        XCTAssertGreaterThanOrEqual(heading.frame.height, heroMinimum)
        for element in [chatHeading, hint, metadata, summary, badge] {
            XCTAssertGreaterThanOrEqual(element.frame.height, bodyMinimum, element.identifier)
        }
        XCTAssertLessThanOrEqual(heading.frame.maxY, metadata.frame.minY)
        XCTAssertLessThanOrEqual(metadata.frame.maxY, summary.frame.minY)
        XCTAssertLessThanOrEqual(chatHeading.frame.maxY, hint.frame.minY)
        if language == "ar" {
            XCTAssertLessThan(hint.frame.midX, heading.frame.midX)
        } else {
            XCTAssertGreaterThan(hint.frame.midX, heading.frame.midX)
        }

        let frame = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        frame.name = "TV Live – \(language)"
        frame.lifetime = .keepAlways
        add(frame)
    }

    @MainActor
    func testEnglishLiveTypography() {
        checkLiveTypography(
            language: "en", title: "Questions after Maghrib", chatTitle: "Live chat",
            description: "Weekly. Questions are answered at the end.")
    }

    @MainActor
    func testArabicLiveTypography() {
        checkLiveTypography(
            language: "ar", title: "أسئلة بعد المغرب", chatTitle: "محادثة البث المباشر",
            description: "كل أسبوع. تُجاب الأسئلة في الآخر.")
    }

    /// With the remote: the stream's button, then a message, each to its own page and back to where it was.
    @MainActor
    private func reportStreamAndMessage(
        _ language: String, streamTitle: String, messageTitle: String, hint: String, toChat: XCUIRemote.Button
    ) {
        let app = openLive(language, FixtureIDs.live)
        let reportStream = app.buttons["tv-report-stream"]
        XCTAssertTrue(reportStream.waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["tv-report-chat-hint"].label, hint)
        let away: XCUIRemote.Button = toChat == .right ? .left : .right
        for _ in 0..<4 where !reportStream.hasFocus { XCUIRemote.shared.press(.down) }
        for _ in 0..<4 where !reportStream.hasFocus { XCUIRemote.shared.press(away) }
        waitForFocus(reportStream)
        XCUIRemote.shared.press(.select)
        checkReportPage(app, title: streamTitle, address: "/\(language)/report?type=livestream&id=\(FixtureIDs.live)")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(gone(app.buttons["tv-report-dismiss"]))
        // The page under it is as it was, not left or loaded again
        waitForFocus(reportStream)

        let focusedChat = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'tv-report-chat-' AND hasFocus == true")
        )
        .firstMatch
        for _ in 0..<6 where !focusedChat.exists { XCUIRemote.shared.press(toChat) }
        for _ in 0..<4 where !focusedChat.exists { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(focusedChat.waitForExistence(timeout: 10))
        let message = String(focusedChat.identifier.dropFirst("tv-report-chat-".count))
        XCUIRemote.shared.press(.select)
        checkReportPage(
            app, title: messageTitle,
            address: "/\(language)/report?type=live_chat&stream=\(FixtureIDs.live)&message=\(message)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(gone(app.buttons["tv-report-dismiss"]))
        waitForFocus(app.buttons["tv-report-chat-\(message)"])
        app.terminate()
    }

    @MainActor
    func testLivePageReportsTheStreamAndAMessage() {
        reportStreamAndMessage(
            "en", streamTitle: "Report live stream", messageTitle: "Report message", hint: "Select a message to report it.",
            toChat: .right)
    }

    @MainActor
    func testArabicLivePageReportsTheStreamAndAMessage() {
        reportStreamAndMessage(
            "ar", streamTitle: "الإبلاغ عن البث المباشر", messageTitle: "الإبلاغ عن الرسالة",
            hint: "اختر رسالة للإبلاغ عنها.", toChat: .left)
    }

    @MainActor
    func testAStreamThatIsNotOnAirCanBeReported() {
        let app = openLive("en", FixtureIDs.coming)
        XCTAssertTrue(app.descendants(matching: .any)["live-notice"].firstMatch.waitForExistence(timeout: 30))
        waitForFocus(app.buttons["tv-report-stream"])
        XCUIRemote.shared.press(.select)
        checkReportPage(
            app, title: "Report live stream", address: "/en/report?type=livestream&id=\(FixtureIDs.coming)")
    }
}

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
        let start = focused.identifier
        let startX = focused.frame.midX
        XCUIRemote.shared.press(next)
        // Focus moves to another card of the rail, in the reading direction (right in English, left in Arabic).
        let moved = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'video-card-trending-' AND hasFocus == true AND identifier != %@", start)
        )
        .firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 15))
        if next == .right {
            XCTAssertGreaterThan(moved.frame.midX, startX)
        } else {
            XCTAssertLessThan(moved.frame.midX, startX)
        }
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
}

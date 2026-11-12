import XCTest

/// Manage on fixtures: edit, search, bulk edit, delete and restore, analytics. English and Arabic.
final class StudioManageTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNLanguage", language, "-AUNTheme", "dark",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func tab(_ app: XCUIApplication, _ name: String) {
        let bar = app.tabBars.buttons[name]
        let button = bar.waitForExistence(timeout: 15) ? bar : app.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "video-\(id)").firstMatch
    }

    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testEditOneVideo() {
        let app = launch("en")
        tab(app, "Content")
        let first = row(app, "fixture-content-1")
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        keep("content-en")
        first.tap()
        let title = app.textFields["edit-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["video-stats"].firstMatch.waitForExistence(timeout: 10))
        // Tap the end of the field, so the text goes after the title.
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        title.typeText(" (revised)")
        keep("edit-en")
        app.buttons["edit-save"].tap()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "part 1 (revised)")).firstMatch
                .waitForExistence(timeout: 10))
    }

    @MainActor
    func testSearchSuggestsTheChannelsOwnVideos() {
        let app = launch("en")
        tab(app, "Content")
        XCTAssertTrue(row(app, "fixture-content-1").waitForExistence(timeout: 20))
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 3) { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("khut")
        let suggestion = app.buttons["suggestion-video:fixture-content-3"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        keep("search-en")
        XCTAssertTrue(row(app, "fixture-content-3").waitForExistence(timeout: 10))
        XCTAssertFalse(row(app, "fixture-content-1").exists)
    }

    @MainActor
    func testBulkEditThenDeleteAndRestore() {
        let app = launch("en")
        tab(app, "Content")
        XCTAssertTrue(row(app, "fixture-content-1").waitForExistence(timeout: 20))
        app.buttons["content-select"].tap()
        row(app, "fixture-content-1").tap()
        row(app, "fixture-content-2").tap()
        XCTAssertTrue(app.staticTexts["2 selected"].waitForExistence(timeout: 10))
        app.buttons["bulk-edit"].tap()
        let visibility = app.buttons["bulk-visibility"].firstMatch
        XCTAssertTrue(visibility.waitForExistence(timeout: 10))
        visibility.tap()
        app.buttons["Private"].firstMatch.tap()
        keep("bulk-edit-en")
        app.buttons["bulk-apply"].tap()
        XCTAssertTrue(app.staticTexts["2 updated"].waitForExistence(timeout: 10))

        // Selection ends after an action; select again.
        if !app.buttons["bulk-delete"].exists {
            app.buttons["content-select"].tap()
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
            if !app.buttons["Done"].exists { app.buttons["content-select"].tap() }
        }
        row(app, "fixture-content-2").tap()
        app.buttons["bulk-delete"].tap()
        XCTAssertTrue(app.buttons["confirm-cancel"].waitForExistence(timeout: 10))
        keep("delete-confirm-en")
        app.buttons["confirm-action"].tap()
        XCTAssertTrue(
            app.staticTexts["1 deleted. Restore from Recently deleted."].waitForExistence(timeout: 10))
        XCTAssertFalse(row(app, "fixture-content-2").waitForExistence(timeout: 2))

        app.buttons["open-deleted"].tap()
        let deleted = app.descendants(matching: .any).matching(identifier: "deleted-fixture-content-2").firstMatch
        XCTAssertTrue(deleted.waitForExistence(timeout: 10))
        deleted.tap()
        keep("recently-deleted-en")
        app.buttons["deleted-restore"].tap()
        let restored = app.staticTexts["1 restored"].waitForExistence(timeout: 10)
        keep("after-restore-en")
        XCTAssertTrue(restored)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row(app, "fixture-content-2").waitForExistence(timeout: 10))
    }

    @MainActor
    func testArabicContentAndAnalytics() {
        let app = launch("ar")
        tab(app, "المحتوى")
        let first = row(app, "fixture-content-1")
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        XCTAssertTrue(first.label.contains("تفسير سورة الكهف"), first.label)
        XCTAssertGreaterThan(first.frame.maxX, app.windows.firstMatch.frame.midX)
        keep("content-ar")
        tab(app, "الإحصاءات")
        XCTAssertTrue(app.descendants(matching: .any)["analytics-chart"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["أبرز المقاطع"].exists)
        // The chart reads as one element with a summary, and the same numbers are offered as a table.
        let chart = app.descendants(matching: .any)["analytics-chart"].firstMatch
        XCTAssertTrue(chart.label.contains("المشاهدات"), chart.label)
        XCTAssertTrue(app.descendants(matching: .any)["analytics-table"].firstMatch.exists)
        keep("analytics-ar")
    }
}

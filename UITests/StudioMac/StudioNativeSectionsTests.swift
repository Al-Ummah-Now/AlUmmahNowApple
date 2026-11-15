import XCTest

/// Studio for Mac sections added for desktop Studio (E19): each opens on fixtures in English and Arabic, dark and light,
/// and keeps a window screenshot for review.
final class StudioNativeSectionsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ section: String, _ language: String, _ theme: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNLanguage", language, "-AUNTheme", theme,
            "-AUNStudioSection", section, "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        // Where the runner may not capture the screen, the fixture app saves its own windows (⌃⌥⌘S).
        if ProcessInfo.processInfo.environment["AUN_LOCAL_SNAPSHOTS"] != nil {
            app.typeKey("s", modifierFlags: [.control, .option, .command])
            Thread.sleep(forTimeInterval: 1.5)
            return
        }
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testCaptionsInEveryLanguageAndTheme() {
        for language in ["en", "ar"] {
            for theme in ["dark", "light"] {
                let app = launch("captions", language, theme)
                XCTAssertTrue(element(app, "draft-ar").waitForExistence(timeout: 30))
                XCTAssertTrue(element(app, "captions-minutes").exists)
                keep(app, "captions-\(language)-\(theme)")
                app.terminate()
            }
        }
    }

    @MainActor
    func testCaptionEditorInArabic() {
        for theme in ["dark", "light"] {
            let app = launch("captions", "ar", theme)
            let edit = element(app, "draft-edit-ar")
            XCTAssertTrue(edit.waitForExistence(timeout: 30))
            edit.click()
            XCTAssertTrue(element(app, "cue-c1").waitForExistence(timeout: 20))
            element(app, "cue-c2").click()
            element(app, "nudge-start-later").click()
            XCTAssertTrue(element(app, "editor-undo").isEnabled)
            keep(app, "caption-editor-ar-\(theme)")
            app.terminate()
        }
    }

    @MainActor
    func testOnDeviceTranscriptionSheet() {
        for language in ["en", "ar"] {
            let app = launch("captions", language, "dark")
            let device = element(app, "captions-transcribe-device")
            XCTAssertTrue(device.waitForExistence(timeout: 30))
            device.click()
            XCTAssertTrue(element(app, "ondevice-model").waitForExistence(timeout: 10))
            keep(app, "ondevice-\(language)-dark")
            app.terminate()
        }
    }
}

import XCTest

/// Studio for Mac sections added for desktop Studio (E19): each opens on fixtures in English and Arabic, dark and light,
/// and keeps a window screenshot for review.
final class StudioNativeSectionsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ section: String, _ language: String, _ theme: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNLanguage", language, "-AUNTheme", theme,
                "-AUNStudioSection", section, "-ApplePersistenceIgnoreState", "YES",
            ] + extra
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

    /// Scrolls the form until `target` is on screen; the CI runner's window is shorter than a desktop one.
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        let scroller = app.scrollViews.firstMatch
        for delta in Array(repeating: -200.0, count: 8) + Array(repeating: 200.0, count: 16) where !target.isHittable {
            scroller.scroll(byDeltaX: 0, deltaY: delta)
        }
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

    @MainActor
    func testDeepAnalyticsInEveryLanguageAndTheme() {
        for language in ["en", "ar"] {
            for theme in ["dark", "light"] {
                let app = launch("analytics", language, theme)
                XCTAssertTrue(element(app, "analytics-all-time").waitForExistence(timeout: 30))
                XCTAssertTrue(element(app, "analytics-export").exists)
                keep(app, "analytics-\(language)-\(theme)")
                let top = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'top-'")).firstMatch
                if top.waitForExistence(timeout: 10) {
                    top.click()
                    XCTAssertTrue(element(app, "video-retention").waitForExistence(timeout: 20))
                    keep(app, "video-analytics-\(language)-\(theme)")
                }
                app.terminate()
            }
        }
    }

    @MainActor
    func testInstitutionSectionsInEveryLanguageAndTheme() {
        for language in ["en", "ar"] {
            for theme in ["dark", "light"] {
                let channels = launch("channels", language, theme)
                XCTAssertTrue(element(channels, "channels-current-fixture-channel").waitForExistence(timeout: 30))
                XCTAssertTrue(element(channels, "channels-switch-fixture-channel-2").exists)
                keep(channels, "channels-\(language)-\(theme)")
                channels.terminate()

                let brand = launch("brand", language, theme)
                XCTAssertTrue(element(brand, "brand-preview").waitForExistence(timeout: 30))
                XCTAssertTrue(element(brand, "brand-save").exists)
                keep(brand, "brand-\(language)-\(theme)")
                brand.terminate()

                let assets = launch("assets", language, theme)
                XCTAssertTrue(element(assets, "asset-a1b2c3d4e5f60001").waitForExistence(timeout: 30))
                XCTAssertTrue(element(assets, "assets-usage").exists)
                keep(assets, "assets-\(language)-\(theme)")
                assets.terminate()
            }
        }
    }

    @MainActor
    func testTeamMemberSeesTheBrandKitReadOnly() {
        let app = launch("channels", "ar", "dark")
        let switchTo = element(app, "channels-switch-fixture-channel-2")
        XCTAssertTrue(switchTo.waitForExistence(timeout: 30))
        switchTo.click()
        XCTAssertTrue(element(app, "channels-current-fixture-channel-2").waitForExistence(timeout: 10))
        element(app, "section-brand").click()
        XCTAssertTrue(element(app, "brand-read-only").waitForExistence(timeout: 20))
        XCTAssertFalse(element(app, "brand-save").exists)
        keep(app, "brand-team-ar-dark")
        app.terminate()
    }

    /// The editor timeline (19.5) on fixtures: three sample clips, the first cut in two by Core.
    @MainActor
    func testEditorInEveryLanguageAndTheme() {
        for language in ["en", "ar"] {
            for theme in ["dark", "light"] {
                let app = launch("editor", language, theme)
                XCTAssertTrue(element(app, "clip-3").waitForExistence(timeout: 60))
                XCTAssertTrue(element(app, "editor-inspector").exists)
                keep(app, "editor-\(language)-\(theme)")
                app.terminate()
            }
        }
    }

    /// Every edit goes through Core and can be undone: split, undo, redo, join and delete from the edit bar.
    @MainActor
    func testEditorEditsAndUndoInArabic() {
        let app = launch("editor", "ar", "dark")
        XCTAssertTrue(element(app, "clip-3").waitForExistence(timeout: 60))
        element(app, "clip-0").click()
        element(app, "editor-join").click()
        XCTAssertTrue(element(app, "clip-2").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "clip-3").exists)
        element(app, "editor-undo").click()
        XCTAssertTrue(element(app, "clip-3").waitForExistence(timeout: 10))
        element(app, "editor-redo").click()
        XCTAssertTrue(element(app, "clip-3").waitForNonExistence(timeout: 10))
        element(app, "clip-1").click()
        element(app, "editor-later").click()
        XCTAssertTrue(element(app, "editor-problem").waitForExistence(timeout: 10))
        keep(app, "editor-refused-ar-dark")
        element(app, "editor-delete").click()
        XCTAssertTrue(element(app, "clip-1").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "clip-2").exists)
        app.terminate()
    }

    /// Pre-encode renditions (19.3) is offered at upload, off by default, and shows its state per file.
    @MainActor
    func testPreEncodeAtUploadInEveryLanguageAndTheme() {
        for language in ["en", "ar"] {
            for theme in ["dark", "light"] {
                let app = launch("upload", language, theme, extra: ["-AUNSampleVideos", "1"])
                let toggle = element(app, "upload-preencode")
                XCTAssertTrue(toggle.waitForExistence(timeout: 60))
                XCTAssertEqual(toggle.value as? Int, 0)
                reveal(toggle, in: app)
                toggle.click()
                keep(app, "preencode-form-\(language)-\(theme)")
                let send = element(app, "upload-send")
                reveal(send, in: app)
                send.click()
                XCTAssertTrue(element(app, "upload-preencode-0").waitForExistence(timeout: 60))
                keep(app, "preencode-queue-\(language)-\(theme)")
                app.terminate()
            }
        }
    }
}

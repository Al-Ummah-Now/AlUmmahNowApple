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

    /// Scrolls the form until `target` is on screen; the CI runner's window is shorter than a desktop one. The
    /// scroll lands in the middle of the window, in the target's column, so the sidebar list is never the one moved.
    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return }
        let column = (target.frame.midX - frame.minX) / frame.width
        let point = window.coordinate(withNormalizedOffset: CGVector(dx: column, dy: 0.5))
        // Hittable alone is true for a button that only peeks in at the bottom, so ask for all of it.
        let visible = frame.insetBy(dx: 0, dy: 8)
        for delta in Array(repeating: -200.0, count: 8) + Array(repeating: 200.0, count: 16)
        where !(target.isHittable && visible.contains(target.frame)) {
            point.scroll(byDeltaX: 0, deltaY: delta)
            Thread.sleep(forTimeInterval: 0.3)
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

    /// Titles and lower thirds (19.5 + 19.9): the fixture project has a title and the brand kit's lower third under the
    /// playhead; selecting the lower third shows its text, place, timing and kit style.
    @MainActor
    func testEditorTitlesInEveryLanguageAndTheme() {
        for language in ["en", "ar"] {
            for theme in ["dark", "light"] {
                let app = launch("editor", language, theme)
                let lowerThird = element(app, "title-1")
                XCTAssertTrue(lowerThird.waitForExistence(timeout: 60))
                XCTAssertTrue(element(app, "title-0").exists)
                lowerThird.click()
                XCTAssertTrue(element(app, "title-edit-text").waitForExistence(timeout: 10))
                XCTAssertTrue(element(app, "title-position").exists)
                Thread.sleep(forTimeInterval: 0.5)
                keep(app, "editor-titles-\(language)-\(theme)")
                app.terminate()
            }
        }
    }

    /// Adding a lower third opens its text; saving, undo and redo go through Core, and delete removes only the title.
    @MainActor
    func testEditorTitleEditsAndUndoInArabic() {
        let app = launch("editor", "ar", "dark")
        XCTAssertTrue(element(app, "title-1").waitForExistence(timeout: 60))
        element(app, "editor-add-lower-third").click()
        let english = element(app, "title-text-en")
        XCTAssertTrue(english.waitForExistence(timeout: 10))
        keep(app, "editor-title-text-ar-dark")
        english.click()
        english.typeKey("a", modifierFlags: .command)
        english.typeText("Second line")
        element(app, "title-save").click()
        XCTAssertTrue(element(app, "title-2").waitForExistence(timeout: 10))
        XCTAssertTrue(english.waitForNonExistence(timeout: 10))
        element(app, "editor-undo").click()
        element(app, "editor-undo").click()
        XCTAssertTrue(element(app, "title-2").waitForNonExistence(timeout: 10))
        element(app, "editor-redo").click()
        XCTAssertTrue(element(app, "title-2").waitForExistence(timeout: 10))
        element(app, "title-0").click()
        element(app, "editor-delete").click()
        XCTAssertTrue(element(app, "title-2").waitForNonExistence(timeout: 10))
        XCTAssertTrue(element(app, "clip-3").exists)
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
                let switchedOn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1"), object: toggle)
                XCTAssertEqual(XCTWaiter().wait(for: [switchedOn], timeout: 10), .completed)
                Thread.sleep(forTimeInterval: 0.5)
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

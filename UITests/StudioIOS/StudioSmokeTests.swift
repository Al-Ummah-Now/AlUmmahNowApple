import XCTest

/// Studio flows on fixtures: no network, English and Arabic.
final class StudioSignInTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ language: String, signedIn: Bool = false, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", signedIn ? "YES" : "NO", "-AUNLanguage", language,
            "-AUNTheme", "dark", "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launchArguments += extra
        app.launch()
        return app
    }

    /// The identity menu: its value is "channel · role · account", each part direction-isolated.
    @MainActor
    private func identity(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "account-button").firstMatch
    }

    @MainActor
    func testContentSearchInBothLanguages() throws {
        for (language, tab, prompt) in [
            ("en", "Content", "Search this channel's videos"),
            ("ar", "المحتوى", "ابحث في مرئيات هذه القناة"),
        ] {
            let app = launch(language, signedIn: true)
            app.openStudioTab(named: tab)
            let search = app.searchFields.matching(NSPredicate(format: "placeholderValue == %@", prompt)).firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 20))
            let screenshot = search.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "content-search-\(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try assertSearchMagnifier(screenshot, rightToLeft: language == "ar")
            search.tap()
            search.typeText("Quran")
            XCTAssertEqual(search.value as? String, "Quran")
            app.terminate()
        }
    }

    private func assertSearchMagnifier(_ screenshot: XCUIScreenshot, rightToLeft: Bool) throws {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let edgeWidth = image.width / 10
        let edge = CGRect(
            x: rightToLeft ? image.width - edgeWidth : 0,
            y: image.height / 4, width: edgeWidth, height: image.height / 2)
        let crop = try XCTUnwrap(image.cropping(to: edge))
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // In the dark fixture theme, the magnifier is bright and the placeholder is muted.
        let brightPixels = (0..<(crop.width * crop.height)).filter { index in
            let offset = index * 4
            return pixels[offset] > 215 && pixels[offset + 1] > 215 && pixels[offset + 2] > 215
        }
        XCTAssertGreaterThan(brightPixels.count, crop.height, "Missing magnifier at the leading edge")
    }

    @MainActor
    func testSignInShowsTheMainChannel() {
        let app = launch("en")
        let signIn = app.buttons["sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Sign in to Studio"].exists)
        signIn.tap()
        let card = identity(app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue((card.value as? String ?? "").contains("Al Ummah Now"), card.debugDescription)
    }

    @MainActor
    func testChannelPickerListsOnlyChannelsYouCanUploadTo() {
        let app = launch("en", signedIn: true)
        let picker = identity(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 30))
        picker.tap()
        // Names and roles are direction-isolated in the label, so match the parts.
        func channel(_ name: String, _ role: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", name, role)).firstMatch
        }
        let editor = channel("Tafsir Circle", "Editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertFalse(channel("Comments desk", "Moderator").exists)
        editor.tap()
        let card = identity(app)
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let switched = NSPredicate(format: "value CONTAINS %@", "Tafsir Circle")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: switched, evaluatedWith: card)], timeout: 10), .completed)
    }

    @MainActor
    func testArabicIsRightToLeft() {
        let app = launch("ar", signedIn: true)
        let account = identity(app)
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        let value = account.value as? String ?? ""
        XCTAssertTrue(value.contains("الأمة الآن"), value)
        XCTAssertTrue(value.contains("مالك"), value)
        // The identity menu sits at the trailing edge: on the left in Arabic.
        XCTAssertLessThan(account.frame.midX, app.windows.firstMatch.frame.midX)
    }

    @MainActor
    func testSignOutExplainsAndFocusesCancel() {
        let app = launch("en", signedIn: true)
        let account = identity(app)
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.tap()
        app.accountsMenuItem.tap()
        let signOut = app.buttons["account-sign-out-fixture-creator"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        signOut.tap()
        XCTAssertTrue(app.buttons["confirm-cancel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sign out of Yusuf Rahman?"].exists)
        app.buttons["confirm-cancel"].tap()
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        signOut.tap()
        app.buttons["confirm-action"].tap()
        XCTAssertTrue(app.buttons["sign-in"].waitForExistence(timeout: 20))
    }

    @MainActor
    func testAddSecondAccountAndSwitchBack() {
        let app = launch("ar", signedIn: true)
        let account = identity(app)
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.tap()
        app.accountsMenuItem.tap()
        app.buttons["account-add"].tap()
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.tap()
        app.accountsMenuItem.tap()
        let first = app.buttons["account-fixture-creator"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["account-fixture-account-1"].exists)
        first.tap()
        app.buttons["accounts-done"].tap()
        XCTAssertTrue(account.waitForExistence(timeout: 10))
    }

    @MainActor
    func testCreatorTermsGatePausesUploadShowsQueueAndResumesAfterAgree() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNLanguage", "en",
            "-AUNTheme", "dark", "-AUNFixtureTermsMode", "refuseUpload", "-AUNSampleVideos", "1",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        XCTAssertTrue(identity(app).waitForExistence(timeout: 30))
        let uploadCandidates = [
            app.tabBars.buttons["Upload"], app.buttons["Upload"].firstMatch, app.cells["Upload"].firstMatch,
            app.cells.containing(.staticText, identifier: "Upload").firstMatch,
        ]
        var openedUpload = false
        for _ in 0..<20 {
            if let hit = uploadCandidates.first(where: { $0.exists && $0.isHittable }) {
                hit.tap()
                openedUpload = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(openedUpload, "Expected Upload tab/item")

        let send = app.buttons["upload-send"]
        for _ in 0..<8 where !send.waitForExistence(timeout: 2) || !send.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()

        // 403 terms_required opens the gate while keeping the paused upload visible underneath.
        let toggle = app.buttons["creator-terms-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        let agree = app.buttons["creator-terms-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 10))
        XCTAssertFalse(agree.isEnabled, "Agree must be a real disabled Button until the checkbox is ticked")
        let queuedJob = app.descendants(matching: .any)["upload-job-0"].firstMatch
        for _ in 0..<4 where !queuedJob.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(queuedJob.exists, "Paused upload job must remain visible under the Creator Terms gate")
        XCTAssertFalse(
            app.buttons["upload-resume-0"].exists,
            "Resume must stay hidden while the job is paused under the open Creator Terms gate")
        XCTAssertTrue(app.buttons["upload-remove-0"].exists)
        XCTAssertTrue(
            app.staticTexts["Waiting for Creator Terms agreement"].waitForExistence(timeout: 5),
            "Paused row under the gate must explain it waits for Creator Terms agreement")
        for _ in 0..<4 where !toggle.isHittable {
            app.swipeDown()
        }

        toggle.tap()
        XCTAssertTrue(agree.isEnabled, "Agree must enable once the checkbox is ticked")
        agree.tap()

        // Gate closes and the paused upload resumes and finishes.
        let closed = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: closed, evaluatedWith: toggle)], timeout: 15), .completed)
        let clearDone = app.buttons["upload-clear-done"]
        for _ in 0..<6 where !clearDone.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(clearDone.exists)
    }

    /// Opens the dialog that deletes the active account.
    @MainActor
    private func openDeletion(_ app: XCUIApplication) -> XCUIElement {
        let account = identity(app)
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        account.tap()
        app.accountsMenuItem.tap()
        let delete = app.buttons["account-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        XCTAssertTrue(app.buttons["delete-account-cancel"].waitForExistence(timeout: 10))
        return delete
    }

    @MainActor
    private func enter(_ word: String, _ app: XCUIApplication) {
        let input = app.textFields["delete-account-confirm-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText(word)
    }

    @MainActor
    func testDeleteAccountRequiresTypedConfirmation() {
        let app = launch("en", signedIn: true)
        let delete = openDeletion(app)
        let confirm = app.buttons["delete-account-confirm"]
        XCTAssertFalse(confirm.isEnabled)
        // Focus is on Cancel, never in the field.
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["delete-account-cancel"].tap()
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        enter("DELETE", app)
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(app.buttons["sign-in"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["notice"].exists)
    }

    @MainActor
    func testADialogClosedAfterWhatStaysBehindAsksForTheWordAgain() {
        let app = launch("ar", signedIn: true, ["-AUNFixtureDeleteMode", "unreadable"])
        let delete = openDeletion(app)
        enter("DELETE", app)
        let confirm = app.buttons["delete-account-confirm"]
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["delete-account-message"].waitForExistence(timeout: 10))
        XCTAssertEqual(confirm.label, "احذفه على أي حال")
        app.swipeDown(velocity: .fast)
        if app.buttons["delete-account-cancel"].exists { app.buttons["delete-account-cancel"].tap() }
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertEqual(confirm.label, "حذف الحساب")
        XCTAssertFalse(confirm.isEnabled)
    }

    @MainActor
    func testALongDeletionCanBeStopped() {
        let app = launch("en", signedIn: true, ["-AUNFixtureDeleteMode", "slow"])
        _ = openDeletion(app)
        enter("DELETE", app)
        app.buttons["delete-account-confirm"].tap()
        let cancel = app.buttons["delete-account-cancel"]
        XCTAssertTrue(app.descendants(matching: .any)["delete-account-progress"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(cancel.label, "Stop")
        XCTAssertTrue(cancel.isEnabled)
        cancel.tap()
        XCTAssertTrue(app.descendants(matching: .any)["delete-account-message"].waitForExistence(timeout: 30))
        XCTAssertEqual(cancel.label, "Cancel")
        cancel.tap()
        app.buttons["accounts-done"].tap()
        // What started is shown on every screen until it is finished.
        XCTAssertTrue(app.descendants(matching: .any)["deletion-banner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["deletion-finish"].exists)
    }

    /// The notice about a deletion shows once on the Dashboard, whatever state the Dashboard is in.
    @MainActor
    func testADeletionNoticeShowsOnceInEveryStateOfTheDashboard() {
        for channels in ["all", "none", "failing", "loading"] {
            let app = launch(
                "en", signedIn: true,
                ["-AUNFixtureDeletionStage", "deleteSent", "-AUNFixtureDeleteMode", "lost", "-AUNFixtureChannels", channels])
            let check = app.buttons["deletion-finish"].firstMatch
            XCTAssertTrue(check.waitForExistence(timeout: 30), channels)
            check.tap()
            let notice = app.descendants(matching: .any).matching(identifier: "notice")
            XCTAssertTrue(notice.firstMatch.waitForExistence(timeout: 15), channels)
            XCTAssertEqual(notice.count, 1, channels)
            app.terminate()
        }
    }

    @MainActor
    func testARestartNeverShowsADeletedAccountSignedIn() {
        let app = launch("en", signedIn: true, ["-AUNFixtureDeletionStage", "deleted", "-AUNFixtureDeleteMode", "lost"])
        XCTAssertTrue(app.buttons["sign-in"].waitForExistence(timeout: 30))
    }
}

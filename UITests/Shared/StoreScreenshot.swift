import XCTest

/// App Store screenshots from the UI tests (`make screenshots`, scripts/screenshots.sh). They run only when the script
/// sets `AUN_SCREENSHOTS=1`, on fixture data (`-AUNUseFixtures YES`): never a QA or production account.
/// Each one is a kept attachment named `store_<language>_<theme>_<NN>_<name>`, which the script files into the fastlane
/// `deliver` layout.
enum StoreScreenshot {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var enabled: Bool { environment["AUN_SCREENSHOTS"] == "1" }

    /// `AUN_REVIEW_SHOTS=1` adds review-only frames of the lower part of long screens (not for the store listing).
    static var reviewShots: Bool { environment["AUN_REVIEW_SHOTS"] == "1" }

    /// `AUN_SCREENSHOT_LANGUAGES` (default `en,ar`).
    static var languages: [String] { list("AUN_SCREENSHOT_LANGUAGES", default: ["en", "ar"]) }

    /// `AUN_SCREENSHOT_THEMES` (default `dark`).
    static var themes: [String] { list("AUN_SCREENSHOT_THEMES", default: ["dark"]) }

    private static func list(_ key: String, default value: [String]) -> [String] {
        let items = (environment[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return items.filter { !$0.isEmpty }.isEmpty ? value : items.filter { !$0.isEmpty }
    }

    /// Launches the app on fixtures in a language and theme.
    @MainActor
    static func launch(_ language: String, _ theme: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-AUNUseFixtures", "YES", "-AUNFixturePlayable", "YES", "-AUNLanguage", language, "-AUNTheme", theme,
                "-ApplePersistenceIgnoreState", "YES",
                // The system's own text for this app (Mac window and menu names from InfoPlist.strings) in the same
                // language; scripts/screenshots.sh also switches the simulator's language for the status bar.
                "-AppleLanguages", "(\(language))",
                "-AppleLocale", language == "ar" ? "ar_SA@calendar=gregorian;numbers=arab" : "en_US",
            ] + extra
        app.launch()
        return app
    }

    #if os(macOS)
        /// Whether the front window opened at `height` points (`-AUNWindowHeight`): a window that reopened at another
        /// height would move every frame edge.
        @MainActor
        static func frontWindow(_ app: XCUIApplication, isTall height: CGFloat) -> Bool {
            abs(app.windows.firstMatch.frame.height - height) < 1
        }
    #endif

    /// The first card of the Trending rail, whichever fixture video leads it.
    @MainActor
    static func firstTrendingCard(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-card-trending-")).firstMatch
    }

    /// Which screenshot: language, theme, position in the store listing and screen name.
    struct Shot {
        let language: String
        let theme: String
        let index: Int
        let name: String
    }

    /// Saves the screen (the app's front window on the Mac) as a kept attachment.
    @MainActor
    static func capture(_ app: XCUIApplication, _ test: XCTestCase, _ shot: Shot) {
        let name = "\(shot.language)_\(shot.theme)_\(String(format: "%02d", shot.index))_\(shot.name)"
        let attachment = XCTAttachment(screenshot: settledScreenshot(app))
        attachment.name = "store_\(name)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
        // Text cut by an edge: kept as its own attachment, which scripts/file-screenshots.py reports and fails the run
        // on once every frame is filed (a failing test here would lose the frames: the script retries, then stops).
        let edges = FrameEdges.read(app)
        if !edges.cuts.isEmpty || reviewShots {
            let report = XCTAttachment(string: (edges.cuts.map { "CUT \($0)" } + edges.layout).joined(separator: "\n"))
            report.name = "\(edges.cuts.isEmpty ? "layout" : "fold")_\(name)"
            report.lifetime = .keepAlways
            test.add(report)
        }
    }

    /// The screen once two frames half a second apart are identical. Images and fonts settle after the first frame, the
    /// tab bar's selection lens finishes its spring and a Mac card redraws around a table that opened, each at its own
    /// pace on a loaded runner: a fixed wait caught the lens still raised in some frames. At most about 15 s.
    @MainActor
    private static func settledScreenshot(_ app: XCUIApplication) -> XCUIScreenshot {
        pause(1.5)
        var last = screenshot(app)
        for _ in 0..<20 {
            pause(0.5)
            let next = screenshot(app)
            if next.pngRepresentation == last.pngRepresentation { return next }
            last = next
        }
        return last
    }

    @MainActor
    private static func screenshot(_ app: XCUIApplication) -> XCUIScreenshot {
        #if os(macOS)
            return app.windows.firstMatch.screenshot()
        #else
            return XCUIScreen.main.screenshot()
        #endif
    }

    /// XCTest's own waiter: spinning the run loop by hand stalled XCUITest on CI (the app "failed to terminate"). CI's
    /// held clock only ever steps back, so a pause can run long, never short.
    private static func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }
}

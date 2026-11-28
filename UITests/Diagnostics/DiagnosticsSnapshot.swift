import SnapshotTesting
import UIKit
import XCTest

/// Captures the Diagnostics row from the presented system menu or Accounts form on the CI iPhone.
@MainActor
enum DiagnosticsSnapshot {
    static func launch(_ language: String, _ theme: String) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Diagnostics references use the CI iPhone")
        let app = XCUIApplication()
        app.launchArguments = [
            "-AUNUseFixtures", "YES", "-AUNFixtureSignedIn", "YES", "-AUNLanguage", language, "-AUNTheme", theme,
            "-AUNTelemetryEnabled", "NO", "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    static func capture(
        _ control: XCUIElement, app: XCUIApplication, language: String, theme: String, test: XCTestCase,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let label = language == "ar" ? "التشخيص وتقارير الأعطال" : "Diagnostics & crash reports"
        XCTAssertTrue(control.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(control.isHittable, file: file, line: line)
        XCTAssertEqual(control.label, label, file: file, line: line)

        let name = "diagnostics-\(language)-\(theme)"
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)

        withSnapshotTesting(record: ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" ? .all : .missing) {
            assertSnapshot(
                of: control.screenshot().image,
                as: .image(precision: 0.97, perceptualPrecision: 0.95),
                named: name, file: file, testName: "settings", line: line)
        }
    }

    static func control(_ app: XCUIApplication, identifier: String, language: String) -> XCUIElement {
        // UIKit can expose a SwiftUI Menu action by its localized title instead of its identifier.
        let label = language == "ar" ? "التشخيص وتقارير الأعطال" : "Diagnostics & crash reports"
        return app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label))
            .firstMatch
    }
}

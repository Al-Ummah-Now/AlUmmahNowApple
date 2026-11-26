import XCTest

extension XCUIApplication {
    /// The Accounts item of the identity menu. iOS 27 menus drop SwiftUI accessibility identifiers on their items, so
    /// it also matches the item's label (en and ar).
    var accountsMenuItem: XCUIElement {
        buttons.matching(NSPredicate(format: "identifier == 'accounts-manage' OR label IN {'Accounts', 'الحسابات'}"))
            .firstMatch
    }

    @MainActor
    func openStudioTab(named name: String) {
        let candidates = [
            tabBars.buttons[name], buttons[name].firstMatch, cells[name].firstMatch,
            cells.containing(.staticText, identifier: name).firstMatch,
        ]
        for _ in 0..<20 {
            if let target = candidates.first(where: { $0.exists && $0.isHittable }) {
                target.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("Expected visible tab or sidebar item: \(name)")
    }
}

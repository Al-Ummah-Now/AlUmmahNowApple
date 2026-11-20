import XCTest

extension XCUIApplication {
    /// The Accounts item of the identity menu. iOS 27 menus drop SwiftUI accessibility identifiers on their items, so
    /// it also matches the item's label (en and ar).
    var accountsMenuItem: XCUIElement {
        buttons.matching(NSPredicate(format: "identifier == 'accounts-manage' OR label IN {'Accounts', 'الحسابات'}"))
            .firstMatch
    }
}

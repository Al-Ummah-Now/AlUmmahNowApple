import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Support and legal links shared by the Studio Accounts sheet and the Identity menu.
struct StudioSupportLinksSection: View {
    @Environment(\.l10n) private var l10n
    let environment: AppEnvironment
    let idPrefix: String

    var body: some View {
        let lang = l10n.language.rawValue
        Link(destination: AUNSupportLinks.help(language: lang, environment: environment)) {
            Label(l10n("common.help"), systemImage: "questionmark.circle")
        }
        .accessibilityIdentifier("\(idPrefix)-help")
        Link(destination: AUNSupportLinks.contact(language: lang, environment: environment)) {
            Label(l10n("common.contact"), systemImage: "envelope")
        }
        .accessibilityIdentifier("\(idPrefix)-contact")
        Link(destination: AUNSupportLinks.privacy(language: lang, environment: environment)) {
            Label(l10n("common.privacyPolicy"), systemImage: "hand.raised")
        }
        .accessibilityIdentifier("\(idPrefix)-privacy")
        Link(destination: AUNSupportLinks.terms(language: lang, environment: environment)) {
            Label(l10n("common.termsOfService"), systemImage: "doc.text")
        }
        .accessibilityIdentifier("\(idPrefix)-terms")
    }
}

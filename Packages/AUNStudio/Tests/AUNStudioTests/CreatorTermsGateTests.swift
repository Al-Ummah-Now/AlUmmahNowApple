import AUNCoreBridge
import AUNDesign
import Foundation
import Testing

@testable import AUNStudio

/// The gate's own rules: what a newly read version does to the tick, the wording and the message.
struct CreatorTermsGateTests {
    private func ticked(_ version: String?) -> CreatorTerms.Gate {
        var gate = CreatorTerms.Gate(version: version)
        gate.agreed = true
        return gate
    }

    @Test func sameVersionKeepsTheTickAndAnUnsavedError() {
        var gate = ticked("v1")
        gate.message = .notSaved("studio.error.generic")
        gate.read("v1", known: "v1")
        #expect(gate.agreed)
        #expect(gate.message == .notSaved("studio.error.generic"))
        gate.read(nil, known: "v1")
        #expect(gate.version == "v1")
        #expect(gate.agreed)
    }

    @Test func anAnswerEndsAReadError() {
        var gate = ticked("v1")
        gate.message = .notRead("studio.error.generic")
        gate.read("v1", known: "v1")
        #expect(gate.message == nil)
        #expect(gate.agreed)
    }

    @Test func anotherVersionClearsTheTickAndIsAnUpdate() {
        var gate = ticked("v1")
        gate.read("v2", known: "v1")
        #expect(gate == CreatorTerms.Gate(version: "v2", updated: true, message: .updated))
    }

    @Test func firstVersionClearsTheTickAndSaysWhy() {
        var gate = ticked(nil)
        gate.message = .notRead("studio.error.offline")
        gate.read("v1", known: nil)
        #expect(gate == CreatorTerms.Gate(version: "v1", message: .loaded))
    }

    @Test func firstVersionWithoutATickOnlyDropsTheReadError() {
        var gate = CreatorTerms.Gate(version: nil, message: .notRead("studio.error.offline"))
        gate.read("v1", known: nil)
        #expect(gate == CreatorTerms.Gate(version: "v1"))
    }

    @Test func aVersionNewerThanTheKnownOneIsAnUpdateEvenWhenNoneWasShown() {
        var gate = ticked(nil)
        gate.read("v2", known: "v1")
        #expect(gate.updated)
        #expect(gate.message == .updated)
        #expect(!gate.agreed)
    }

    @Test func aRefusedAgreementNeedsANewTickAndStaysAnUpdate() {
        var gate = ticked("v1")
        gate.refuse(current: "v2")
        #expect(gate == CreatorTerms.Gate(version: "v2", updated: true, message: .updated))
        // The server did not say which: none is sent until it is read.
        gate.agreed = true
        gate.refuse(current: nil)
        #expect(gate.version == nil)
        #expect(!gate.agreed)
    }

    @MainActor @Test func everyMessageAndLabelExistsInBothLanguages() {
        let messages: [CreatorTerms.Message] = [
            .updated, .loaded, .notRead("studio.error.offline"), .notSaved("studio.error.generic"),
        ]
        let keys =
            messages.map(\.key) + [
                "studio.terms.title", "studio.terms.body", "studio.terms.updatedBody", "studio.terms.checkbox",
                "studio.terms.agree", "studio.terms.saving", "studio.upload.state.waitingForTerms",
                UploadQueue.termsRequiredKey, "common.help", "common.contact", "common.privacyPolicy",
                "common.termsOfService", "common.communityGuidelines", "common.dismiss",
            ]
        for language in AppLanguage.allCases {
            for key in keys {
                let value = L10n(language)(key)
                #expect(!value.isEmpty && !value.contains("⟦"), "\(language.rawValue): \(key)")
            }
        }
    }

    @Test func supportLinksUseEnvironmentHostsAcrossQAStageAndProd() {
        let qa = AppEnvironment.qa
        #expect(qa.webBaseURL.absoluteString == "https://videos.qa.alummahnow.net")
        #expect(qa.wwwBaseURL.absoluteString == "https://www.qa.alummahnow.net")
        #expect(
            AUNSupportLinks.help(language: "en", environment: qa).absoluteString == "https://videos.qa.alummahnow.net/en/help")
        #expect(
            AUNSupportLinks.privacy(language: "ar", environment: qa).absoluteString == "https://www.qa.alummahnow.net/ar/privacy/"
        )

        let stage = AppEnvironment(
            name: "stage",
            apiBaseURL: URL(string: "https://videos.api.stage.alummahnow.net")!,
            adminAPIBaseURL: URL(string: "https://admin.api.stage.alummahnow.net")!,
            authIssuer: URL(string: "https://auth.stage.alummahnow.net")!)
        #expect(stage.webBaseURL.absoluteString == "https://videos.stage.alummahnow.net")
        #expect(stage.wwwBaseURL.absoluteString == "https://www.stage.alummahnow.net")

        let prod = AppEnvironment(
            name: "prod",
            apiBaseURL: URL(string: "https://videos.api.alummahnow.net")!,
            adminAPIBaseURL: URL(string: "https://admin.api.alummahnow.net")!,
            authIssuer: URL(string: "https://auth.alummahnow.net")!)
        #expect(prod.webBaseURL.absoluteString == "https://videos.alummahnow.net")
        #expect(prod.wwwBaseURL.absoluteString == "https://www.alummahnow.net")
        #expect(AUNSupportLinks.terms(language: "en", environment: prod).absoluteString == "https://www.alummahnow.net/en/terms/")
    }
}

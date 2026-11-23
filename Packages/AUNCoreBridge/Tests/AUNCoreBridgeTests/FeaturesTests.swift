import Foundation
import Testing

@testable import AUNCoreBridge

/// `GET /api/me/features` and the 404 `feature_off` answer of gated APIs (owner rule 2026-11-16: off = invisible).
struct FeaturesTests {
    private let base = URL(string: "https://videos.api.qa.alummahnow.net")!

    private func service(_ handler: @escaping StubURLProtocol.Handler) -> NativeStudioService {
        NativeStudioService(
            baseURL: base, accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]),
            session: StubURLProtocol.session(handler: handler))
    }

    private func decode(_ json: String) throws -> UserFeatures {
        try JSONDecoder().decode(UserFeatures.self, from: Data(json.utf8))
    }

    @Test func onlyTrueKeysAreOnAndMissingOrUnknownKeysAreOff() throws {
        let features = try decode(
            #"{"success":true,"version":1,"features":{"upload":true,"live":false,"bulkSchedule":"yes","teleport":true}}"#)
        #expect(features.isOn(.upload))
        #expect(!features.isOn(.live))
        // Not a boolean: off. Missing: off. A key the app does not know is dropped.
        #expect(!features.isOn(.bulkSchedule))
        #expect(!features.isOn(.createChannel))
        #expect(features.on == [.upload])
    }

    @Test func readsTheFlagsUnderAnEnvelopeOrAtTheTopLevel() throws {
        #expect(try decode(#"{"data":{"features":{"createChannel":true}}}"#).on == [.createChannel])
        #expect(try decode(#"{"result":{"quranText":true}}"#).on == [.quranText])
        #expect(try decode(#"{"upload":true,"live":true}"#).on == [.upload, .live])
        #expect(try decode("{}") == .none)
        #expect(try decode(#"{"features":null}"#) == .none)
    }

    @Test func everyServerKeyIsKnown() {
        // The shared-types USER_FEATURE_KEYS list, version 1.
        let keys = [
            "upload", "createChannel", "live", "captionsTranscribe", "captionsTranslate", "inlineTranslate",
            "viewerTranslatedTitles", "quranEditions", "quranText", "audioTracks", "siteDomains", "socialAutopost",
            "youtubeImport", "aiCategorySuggest", "bulkSchedule", "eventCalendar",
        ]
        #expect(Set(keys.compactMap(UserFeature.init(rawValue:))) == Set(UserFeature.allCases))
        #expect(UserFeatures.all.on.count == keys.count)
    }

    @Test func featuresSendTheChannel() async throws {
        let features = try await service { request in
            #expect(request.url?.path() == "/api/me/features")
            #expect(request.url?.query() == "channelId=c1")
            return (200, [:], Data(#"{"success":true,"version":1,"features":{"upload":true}}"#.utf8))
        }.features(channelID: "c1")
        #expect(features.on == [.upload])
        _ = try await service { request in
            #expect(request.url?.query() == nil)
            return (200, [:], Data(#"{"version":1,"features":{}}"#.utf8))
        }.features(channelID: nil)
    }

    @Test func aGatedApiThatIsOffAnswersFeatureOff() async {
        await #expect(throws: CoreError.featureOff) {
            try await service { _ in (404, [:], Data(#"{"success":false,"code":"feature_off"}"#.utf8)) }
                .channelStats(channelID: "c1", period: DateInterval(start: .now.addingTimeInterval(-86_400), end: .now))
        }
        // Any other 404 stays "not found".
        await #expect(throws: CoreError.notFound) {
            try await service { _ in (404, [:], Data(#"{"success":false,"error":"Not found"}"#.utf8)) }
                .channelStats(channelID: "c1", period: DateInterval(start: .now.addingTimeInterval(-86_400), end: .now))
        }
    }

    @Test func tierAndOffAnswersHideTheEntryPoint() {
        #expect(CoreError.featureOff.hidesEntryPoint)
        #expect(CoreError.http(status: 402).hidesEntryPoint)
        #expect(CoreError.refused(Refusal(code: Refusal.upgradeRequired)).hidesEntryPoint)
        #expect(CoreError.refused(Refusal(code: Refusal.uploadsByInvitation)).hidesEntryPoint)
        // Quotas and account states are plain facts, not hidden.
        #expect(!CoreError.http(status: 429).hidesEntryPoint)
        #expect(!CoreError.refused(Refusal(code: Refusal.uploadLimit)).hidesEntryPoint)
        #expect(!CoreError.refused(Refusal(code: Refusal.channelLimit)).hidesEntryPoint)
        #expect(!CoreError.refused(Refusal(code: Refusal.accountPendingDeletion)).hidesEntryPoint)
        #expect(!CoreError.notFound.hidesEntryPoint)
    }

    @Test func fixturesSwitchFeaturesOffForUITests() async throws {
        #expect(try await FixtureStudioService().features(channelID: nil) == .all)
        let invitation = try await FixtureStudioService(accountState: .invitation).features(channelID: nil)
        #expect(!invitation.isOn(.upload) && !invitation.isOn(.createChannel) && invitation.isOn(.bulkSchedule))
        let off = FixtureStudioService(featuresOff: ["bulkSchedule", "analytics"])
        #expect(try await !off.features(channelID: nil).isOn(.bulkSchedule))
        await #expect(throws: CoreError.featureOff) {
            try await off.channelStats(channelID: "c1", period: DateInterval(start: .now.addingTimeInterval(-86_400), end: .now))
        }
    }
}

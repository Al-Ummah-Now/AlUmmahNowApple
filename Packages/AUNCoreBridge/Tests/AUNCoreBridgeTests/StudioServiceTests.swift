import Foundation
import Testing

@testable import AUNCoreBridge

struct StudioServiceTests {
    private let base = URL(string: "https://videos.api.qa.alummahnow.net")!

    private func service(signedIn: Bool = true, _ handler: @escaping StubURLProtocol.Handler) -> NativeStudioService {
        NativeStudioService(
            baseURL: base,
            accounts: FixtureAccountService(signedIn: signedIn ? [FixtureAccountService.creator] : []),
            session: StubURLProtocol.session(handler: handler))
    }

    @Test func channelsUseTheBearerTokenAndNoChannelHeader() async throws {
        let body = """
            {"success":true,"data":[
              {"id":"c1","userId":"u1","name":"Main","nameLocalized":{"ar":"الرئيسية"},"isMain":true,"role":"owner",
               "capabilities":["video.upload"],"handle":"main"},
              {"id":"c2","userId":"u2","name":"Helped","isMain":false,"role":"moderator","capabilities":["comment.moderate"]},
              {"id":"c3","userId":"u3","name":"Paused","isMain":false,"role":"owner","capabilities":[],"isSuspended":true},
              {"id":"c4","userId":"u4","name":"Future","role":"curator"}
            ]}
            """
        let channels = try await service { request in
            #expect(request.url?.path() == "/api/channels/access")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            #expect(request.value(forHTTPHeaderField: "channelId") == nil)
            return (200, [:], Data(body.utf8))
        }.channels()
        #expect(channels.map(\.id) == ["c1", "c2", "c3", "c4"])
        #expect(channels[0].displayName(.ar) == "الرئيسية")
        #expect(channels[0].displayName(.en) == "Main")
        #expect(channels.map(\.canUpload) == [true, false, false, false])
        #expect(channels[3].role == .moderator)
    }

    @Test func signedOutNeverCallsTheServer() async {
        await #expect(throws: CoreError.signInRequired) {
            try await service(signedIn: false) { _ in
                Issue.record("no request expected")
                return (500, [:], Data())
            }.channels()
        }
    }

    @Test func serverErrorsMapOntoCoreErrors() async {
        for (status, expected) in [
            (401, CoreError.signInRequired), (403, .forbidden), (404, .notFound), (503, .http(status: 503)),
        ] {
            await #expect(throws: expected) {
                try await service { _ in (status, [:], Data(#"{"success":false,"error":"x"}"#.utf8)) }.channels()
            }
        }
        await #expect(throws: CoreError.invalid("Title is required")) {
            try await service { _ in (400, [:], Data(#"{"success":false,"error":"Title is required"}"#.utf8)) }.channels()
        }
    }
}

import Foundation
import Testing

@testable import AUNCoreBridge

/// The Dashboard's comments awaiting review, and the names shown for people: display name, else first + last, else
/// email; never an @handle.
struct HeldCommentsTests {
    private func service(_ handler: @escaping StubURLProtocol.Handler) -> NativeStudioService {
        NativeStudioService(
            baseURL: URL(string: "https://videos.api.qa.alummahnow.net")!,
            accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]),
            session: StubURLProtocol.session(handler: handler))
    }

    @Test func readsTheHeldTabForTheChannel() async throws {
        let body = """
            {"success":true,"items":[
              {"id":"m1","text":"Jazakum Allahu khayran","targetTitle":"Seerah, part 1","createdAt":"2026-11-15T10:00:00Z",
               "author":{"id":"u1","username":"maryam_h","resolvedDisplayName":"Maryam Haddad","displayName":"Maryam"}},
              {"id":"m2","text":"?","targetTitle":"Tafsir","author":{"username":"omar99","firstName":"Omar","lastName":"Saleh"}}
            ],"nextCursor":null,"total":7}
            """
        let held = try await service { request in
            #expect(request.url?.path() == "/api/channels/c1/comments")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.contains(URLQueryItem(name: "tab", value: "held")))
            #expect(items.contains(URLQueryItem(name: "limit", value: "4")))
            #expect(request.value(forHTTPHeaderField: "channelId") == "c1")
            return (200, [:], Data(body.utf8))
        }.heldComments(channelID: "c1", limit: 4)
        #expect(held.total == 7)
        #expect(held.items.map(\.id) == ["m1", "m2"])
        #expect(held.items.map(\.authorName) == ["Maryam Haddad", "Omar Saleh"])
        #expect(held.items[0].targetTitle == "Seerah, part 1")
    }

    @Test func theTargetTitleFollowsThePageLanguage() throws {
        let json = #"""
            {"id":"c","text":"Jazakum Allahu khayran","targetTitle":"Friday khutbah: patience",
             "targetTitleLocalized":{"en":"Friday khutbah: patience","ar":"خطبة الجمعة: الصبر"}}
            """#
        let comment = try JSONDecoder().decode(HeldComment.self, from: Data(json.utf8))
        #expect(comment.displayTargetTitle(.ar) == "خطبة الجمعة: الصبر")
        #expect(comment.displayTargetTitle(.en) == "Friday khutbah: patience")
        #expect(comment.text == "Jazakum Allahu khayran")
        // No Arabic title (or none at all): the plain title.
        let plain = try JSONDecoder().decode(
            HeldComment.self,
            from: Data(#"{"id":"c","text":"t","targetTitle":"Seerah","targetTitleLocalized":{"ar":" "}}"#.utf8))
        #expect(plain.displayTargetTitle(.ar) == "Seerah")
        let bare = try JSONDecoder().decode(HeldComment.self, from: Data(#"{"id":"c","text":"t","targetTitle":"Seerah"}"#.utf8))
        #expect(bare.displayTargetTitle(.ar) == "Seerah")
    }

    @Test func aFeatureOffAnswerHidesTheSection() async {
        await #expect(throws: CoreError.featureOff) {
            try await service { _ in
                (404, [:], Data(#"{"success":false,"code":"feature_off","error":"Not found"}"#.utf8))
            }.heldComments(channelID: "c1", limit: 4)
        }
    }

    @Test(arguments: [
        (#"{"resolvedDisplayName":"Server Name","displayName":"Shown","username":"handle"}"#, "Server Name"),
        (#"{"displayName":"  Shown  ","firstName":"A","lastName":"B","username":"handle"}"#, "Shown"),
        (#"{"displayName":" ","firstName":"Aisha","lastName":"Rahman","username":"handle"}"#, "Aisha Rahman"),
        (#"{"firstName":"Aisha","username":"handle"}"#, "Aisha"),
        (#"{"username":"handle","handle":"@handle"}"#, ""),
    ])
    func authorNamesNeverUseTheHandle(author: String, name: String) throws {
        let json = #"{"id":"c","text":"t","targetTitle":"v","author":"# + author + "}"
        let comment = try JSONDecoder().decode(HeldComment.self, from: Data(json.utf8))
        #expect(comment.authorName == name)
    }

    @Test func accountsReadDisplayNameThenEmailNeverTheId() {
        #expect(StudioAccount(id: "u1", email: "a@x.test", displayName: "Aisha Rahman").name == "Aisha Rahman")
        #expect(StudioAccount(id: "u1", email: "a@x.test", displayName: "  ").name == "a@x.test")
        #expect(StudioAccount(id: "u1", email: "a@x.test").name == "a@x.test")
        #expect(StudioAccount(id: "u1").name == nil)
        #expect(StudioAccount(id: "u1").label == "u1")
    }
}

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
              {"id":"m1","kind":"video","targetId":"v1","text":"Jazakum Allahu khayran","targetTitle":"Seerah, part 1","createdAt":"2026-11-15T10:00:00Z",
               "author":{"userId":"u1","channelId":"author-channel","username":"maryam_h","resolvedDisplayName":"Maryam Haddad","displayName":"Maryam"}},
              {"id":"m2","kind":"post","targetId":"p1","heldBy":"moderation","text":"?","targetTitle":"Tafsir","author":{"username":"omar99","firstName":"Omar","lastName":"Saleh"}}
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
        #expect(held.items.map(\.kind) == [.video, .post])
        #expect(held.items.map(\.targetID) == ["v1", "p1"])
        #expect(held.items[0].authorUserID == "u1")
        #expect(held.items[1].authorUserID == nil)
        #expect(held.items.map(\.canModerate) == [true, false])
    }

    @Test(arguments: [HeldCommentModeration.approve, .remove], [HeldCommentKind.video, .post])
    func moderatesVideoAndPostComments(action: HeldCommentModeration, kind: HeldCommentKind) async throws {
        let comment = actionableComment(kind: kind)
        try await service { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path() == "/api/channels/c1/comments/bulk")
            #expect(request.value(forHTTPHeaderField: "channelId") == "c1")
            let body = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
            #expect(body["action"] as? String == action.rawValue)
            #expect(
                body["items"] as? [[String: String]] == [
                    ["kind": kind.rawValue, "targetId": "target", "commentId": "comment"]
                ])
            return (200, [:], Data(#"{"success":true,"results":[{"commentId":"comment","ok":true}]}"#.utf8))
        }.moderateHeldComment(comment, action: action, channelID: "c1")
    }

    @Test(arguments: [
        ("held_by_moderation", CoreError.conflict("held_by_moderation")),
        ("not_in_channel", CoreError.notFound),
        ("failed", CoreError.http(status: 500)),
    ])
    func rejectsFailedModerationItems(code: String, error: CoreError) async {
        let json = """
            {"success":true,"results":[{"commentId":"comment","ok":false,"error":"\(code)"}]}
            """
        await #expect(throws: error) {
            try await service { _ in (200, [:], Data(json.utf8)) }
                .moderateHeldComment(actionableComment(), action: .approve, channelID: "c1")
        }
    }

    @Test func sendsAReportAsTheSignedInPerson() async throws {
        try await service { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path() == "/api/moderation/reports")
            #expect(request.value(forHTTPHeaderField: "channelId") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request))
            #expect(
                body as? [String: String] == [
                    "entityType": "comment", "entityId": "comment", "reason": "child_safety", "description": "Details",
                ])
            return (200, [:], Data(#"{"success":true,"result":{"report":{"id":"r1"}}}"#.utf8))
        }.reportHeldComment(id: "comment", reason: .childSafety, description: "Details")
    }

    @Test func passesThroughDuplicateReportConflict() async {
        await #expect(throws: CoreError.conflict("You have already reported this content")) {
            try await service { _ in
                (409, [:], Data(#"{"success":false,"error":"You have already reported this content"}"#.utf8))
            }.reportHeldComment(id: "comment", reason: .spam, description: nil)
        }
    }

    @Test func blocksThePersonOnTheSelectedChannel() async throws {
        try await service { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path() == "/api/channels/c1/blocks")
            #expect(request.value(forHTTPHeaderField: "channelId") == "c1")
            let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request))
            #expect(body as? [String: String] == ["userId": "person"])
            return (200, [:], Data(#"{"success":true}"#.utf8))
        }.hideCommentAuthor(userID: "person", channelID: "c1")
    }

    @Test(arguments: [
        (400, "cannot_block_member", CoreError.invalid("cannot_block_member")),
        (404, "user_not_found", CoreError.notFound),
        (503, "index_unavailable", CoreError.http(status: 503)),
    ])
    func passesThroughBlockErrors(status: Int, code: String, error: CoreError) async {
        await #expect(throws: error) {
            try await service { _ in
                (status, [:], Data("{\"success\":false,\"error\":\"\(code)\"}".utf8))
            }.hideCommentAuthor(userID: "person", channelID: "c1")
        }
    }

    private func actionableComment(kind: HeldCommentKind = .video) -> HeldComment {
        HeldComment(id: "comment", text: "Test comment", targetTitle: "Title", authorName: "Name", kind: kind, targetID: "target")
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

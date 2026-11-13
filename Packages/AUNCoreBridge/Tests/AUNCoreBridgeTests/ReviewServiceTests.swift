import Foundation
import Testing

@testable import AUNCoreBridge

/// admin-api review routes (AlUmmahNow #1280) and the push registry (#1278), against stubbed responses.
struct ReviewServiceTests {
    private let admin = URL(string: "https://admin.api.qa.alummahnow.net")!
    private let videos = URL(string: "https://videos.api.qa.alummahnow.net")!

    private func service(_ handler: @escaping StubURLProtocol.Handler) -> NativeReviewService {
        NativeReviewService(
            adminAPI: admin, videosAPI: videos,
            accounts: FixtureAccountService(signedIn: [StudioAccount(id: "u1", displayName: "Reviewer")]),
            session: StubURLProtocol.session(handler: handler))
    }

    private func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    @Test func theQueueDecodesD1RowsWithTheBearerToken() async throws {
        let row: [String: Any] = [
            "id": "r1", "subject_id": "v1", "status": "in_review", "risk": 0.7, "nsfw": 1, "escalate": 0,
            "hold_cause": "nsfw", "top_category": "sexual", "sla_due_at": "2026-11-13T12:00:00.000Z",
            "assigned_to": NSNull(), "findings_count": 2,
        ]
        let payload = json(["success": true, "result": ["items": [row], "nextCursor": NSNull()]])
        let service = service { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            #expect(request.url?.path == "/api/review/queue")
            #expect(request.url?.query?.contains("tab=action_needed") == true)
            #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
            return (200, [:], payload)
        }
        let page = try await service.queue(.actionNeeded, query: nil, cursor: nil)
        #expect(page.items.count == 1)
        #expect(page.items[0].nsfw)
        #expect(!page.items[0].escalate)
        #expect(page.items[0].holdCause == .nsfw)
        #expect(page.items[0].isSensitive)
        #expect(page.items[0].slaDueAt != nil)
    }

    @Test func anIdFromALinkOrPushNeverReachesAnotherRoute() async throws {
        let service = service { request in
            Issue.record("unexpected request \(request.url?.absoluteString ?? "")")
            return (200, [:], Data())
        }
        for id in ["../users", "r1/claim", "%2e%2e", "r1?x=1", "r1#x", "", String(repeating: "a", count: 65), "رقم"] {
            #expect(!ReviewID.isValid(id))
            await #expect(throws: CoreError.self) { try await service.claim(id) }
        }
        #expect(ReviewID.isValid("fx-minor_2"))
    }

    @Test func aConflictSaysWhoDecided() async throws {
        let service = service { _ in
            (
                409, [:],
                self.json([
                    "success": false, "code": "already_decided", "error": "x", "decision": "approve",
                    "decidedByName": "Amina", "decidedAt": "2026-11-13T12:00:00Z",
                ])
            )
        }
        await #expect(throws: ReviewError.self) {
            _ = try await service.decide("r1", .approve, reason: nil, note: nil, version: 3)
        }
        do {
            _ = try await service.decide("r1", .approve, reason: nil, note: nil, version: 3)
        } catch let ReviewError.alreadyDecided(decision, name, at) {
            #expect(decision == "approve")
            #expect(name == "Amina")
            #expect(at != nil)
        }
    }

    @Test func aDecisionSendsTheVersionAndReason() async throws {
        let service = service { request in
            let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            #expect(body?["decision"] as? String == "reject")
            #expect(body?["reasonCode"] as? String == "spam_scam")
            #expect(body?["version"] as? Int == 4)
            return (
                200, [:],
                self.json(["success": true, "result": ["review": ["id": "r1", "subject_id": "v1", "status": "rejected"]]])
            )
        }
        let result = try await service.decide("r1", .reject, reason: .spamScam, note: "", version: 4)
        #expect(result.item.status == "rejected")
    }

    @Test func notAReviewerIsNotStaff() async {
        let service = service { _ in (403, [:], self.json(["success": false, "code": "reviewer_only"])) }
        await #expect(throws: ReviewError.notStaff) { _ = try await service.profile() }
    }

    @Test func meReadsRolesAndSeniority() async throws {
        let service = service { request in
            #expect(request.url?.path == "/api/me")
            return (
                200, [:],
                self.json(["success": true, "result": ["userId": "u1", "roles": ["Senior Reviewer"], "permissions": []]])
            )
        }
        let profile = try await service.profile()
        #expect(profile.isReviewer)
        #expect(profile.isSeniorReviewer)
    }

    @Test func withoutAMeRouteTheQueueAnswers() async throws {
        let service = service { request in
            if request.url?.path == "/api/me" { return (404, [:], Data()) }
            return (200, [:], self.json(["success": true, "result": ["items": [], "nextCursor": NSNull()]]))
        }
        let profile = try await service.profile()
        #expect(profile.userID == "u1")
        #expect(!profile.isSeniorReviewer)
    }

    @Test func pushRegistersAsTheAdminApp() async throws {
        let service = service { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.absoluteString == "https://videos.api.qa.alummahnow.net/api/v1/devices/install1234")
            let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            #expect(body?["app"] as? String == "admin")
            #expect(body?["provider"] as? String == "apns")
            #expect(body?["platform"] as? String == "ios")
            return (200, [:], Data("{}".utf8))
        }
        try await service.register(installID: "install1234", token: "abcd", platform: "ios", locale: "en", appVersion: "1.0")
    }

    @Test func roleNamesReadLikeTheServer() {
        #expect(StaffProfile(userID: "a", roles: ["Super Admin"]).isSeniorReviewer)
        #expect(StaffProfile(userID: "a", roles: ["content-reviewer"]).isReviewer)
        #expect(!StaffProfile(userID: "a", roles: ["content_reviewer"]).isSeniorReviewer)
        #expect(!StaffProfile(userID: "a", roles: ["creator"]).isReviewer)
    }
}

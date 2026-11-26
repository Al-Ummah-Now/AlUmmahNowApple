import Foundation
import Testing

@testable import AUNCoreBridge

@Suite struct NativeDeletionServiceTests {
    private let api = URL(string: "https://api.example.com")!
    private let auth = URL(string: "https://auth.example.com")!

    private struct Proofs: NativeProofProviding {
        func proof(account: String, fresh: Bool) async -> String? { fresh ? "fresh-\(account)" : "old-\(account)" }
    }

    private func service(
        proofs: (any NativeProofProviding)? = nil, _ handler: @escaping StubURLProtocol.Handler
    ) -> NativeDeletionService {
        NativeDeletionService(
            apiBaseURL: api, authIssuer: auth, proofs: proofs, session: StubURLProtocol.session(handler: handler))
    }

    @Test func eraseSendsTheWordTheTokenAndTheResumeToken() async throws {
        let answer = try await service { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.absoluteString == "https://api.example.com/api/privacy/data")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
            #expect(request.value(forHTTPHeaderField: "X-AUN-Native-Proof") == nil)
            let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: String]
            #expect(body == ["confirm": "DELETE", "resumeToken": "r"])
            return (503, ["Retry-After": "300"], Data("{}".utf8))
        }.erase(accountID: "u1", token: "t", resumeToken: "r")
        #expect(answer.status == 503)
        #expect(answer.retryAfter == "300")
    }

    @Test func aMissingProofIsMadeAgainOnceForTheAccountItself() async throws {
        let answer = try await service(proofs: Proofs()) { request in
            let proof = request.value(forHTTPHeaderField: "X-AUN-Native-Proof")
            return proof == "fresh-u1"
                ? (200, [:], Data(#"{"complete":true}"#.utf8))
                : (403, [:], Data(#"{"code":"native_proof_required"}"#.utf8))
        }.erase(accountID: "u1", token: "t", resumeToken: nil)
        #expect(answer.status == 200)
    }

    @Test func theReceiptTheAccountAndItsStatusAreAskedOfAuth() async throws {
        let service = service { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let line = "\(request.httpMethod ?? "") \(request.url?.absoluteString ?? "") \(authorization)"
            return (200, [:], Data(line.utf8))
        }
        func line(_ answer: DeletionAnswer) -> String? { String(bytes: answer.body, encoding: .utf8) }
        let host = "https://auth.example.com"
        #expect(line(try await service.deleteAccount(token: "t")) == "DELETE \(host)/account Bearer t")
        #expect(
            line(try await service.deletionReceipt(token: "t")) == "POST \(host)/account/deletion-receipt Bearer t")
        #expect(
            line(try await service.accountStatus(receipt: "r")) == "GET \(host)/account/status Deletion-Receipt r")
    }

    @Test func theServersClockIsItsDateHeader() async {
        let now = await service { _ in (200, ["Date": "Fri, 15 Jan 2027 08:00:00 GMT"], Data()) }.serverNow()
        #expect(now == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(await service { _ in (200, [:], Data()) }.serverNow() == nil)
    }

    @Test func aRequestHasALimitedTime() {
        let configuration = NativeDeletionService.limited().configuration
        #expect(configuration.timeoutIntervalForResource == 60)
        #expect(configuration.timeoutIntervalForRequest == 60)
    }
}

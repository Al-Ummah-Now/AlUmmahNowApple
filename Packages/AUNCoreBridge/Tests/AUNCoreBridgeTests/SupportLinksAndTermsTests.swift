import Foundation
import Testing

@testable import AUNCoreBridge

@Suite("SupportLinksAndTermsTests")
struct SupportLinksAndTermsTests {
    @Test func supportLinksMatchLocaleAndEnvironmentDomains() {
        let prod = AppEnvironment(name: "prod", apiBaseURL: URL(string: "https://videos.api.alummahnow.net")!)
        #expect(AUNSupportLinks.help(language: "en", environment: prod).absoluteString == "https://videos.alummahnow.net/en/help")
        #expect(AUNSupportLinks.help(language: "ar", environment: prod).absoluteString == "https://videos.alummahnow.net/ar/help")
        #expect(
            AUNSupportLinks.contact(language: "en", environment: prod).absoluteString
                == "https://videos.alummahnow.net/en/contact")
        #expect(
            AUNSupportLinks.contact(language: "ar", environment: prod).absoluteString
                == "https://videos.alummahnow.net/ar/contact")
        #expect(
            AUNSupportLinks.privacy(language: "en", environment: prod).absoluteString == "https://www.alummahnow.net/en/privacy/")
        #expect(
            AUNSupportLinks.privacy(language: "ar", environment: prod).absoluteString == "https://www.alummahnow.net/ar/privacy/")
        #expect(AUNSupportLinks.terms(language: "en", environment: prod).absoluteString == "https://www.alummahnow.net/en/terms/")
        #expect(AUNSupportLinks.terms(language: "ar", environment: prod).absoluteString == "https://www.alummahnow.net/ar/terms/")
        #expect(
            AUNSupportLinks.communityGuidelines(language: "ar", environment: prod).absoluteString
                == "https://videos.alummahnow.net/ar/community-guidelines"
        )

        let qa = AppEnvironment.qa
        #expect(
            AUNSupportLinks.help(language: "en", environment: qa).absoluteString == "https://videos.qa.alummahnow.net/en/help")
        #expect(
            AUNSupportLinks.contact(language: "ar", environment: qa).absoluteString
                == "https://videos.qa.alummahnow.net/ar/contact")
        #expect(
            AUNSupportLinks.communityGuidelines(language: "en", environment: qa).absoluteString
                == "https://videos.qa.alummahnow.net/en/community-guidelines"
        )
        #expect(
            AUNSupportLinks.privacy(language: "en", environment: qa).absoluteString == "https://www.qa.alummahnow.net/en/privacy/"
        )
        #expect(
            AUNSupportLinks.terms(language: "ar", environment: qa).absoluteString == "https://www.qa.alummahnow.net/ar/terms/")

        // Unknown host falls back to QA, never to production.
        let unknown = AppEnvironment(name: "dev", apiBaseURL: URL(string: "https://example.invalid")!)
        #expect(
            AUNSupportLinks.terms(language: "en", environment: unknown).absoluteString
                == "https://www.qa.alummahnow.net/en/terms/")
        #expect(
            AUNSupportLinks.help(language: "en", environment: unknown).absoluteString
                == "https://videos.qa.alummahnow.net/en/help")
    }

    @Test func creatorAccessDecodesTermsAcceptedAndVersion() throws {
        let pending = try JSONDecoder().decode(
            CreatorAccess.self,
            from: Data(
                #"{"canUpload":true,"canCreateChannel":true,"termsAccepted":false,"termsVersion":"2026-11-24"}"#.utf8)
        )
        #expect(pending.termsAccepted == false)
        #expect(pending.termsVersion == "2026-11-24")

        let accepted = try JSONDecoder().decode(
            CreatorAccess.self,
            from: Data(
                #"{"canUpload":true,"canCreateChannel":true,"termsAccepted":true,"termsVersion":"2026-11-24"}"#.utf8)
        )
        #expect(accepted.termsAccepted == true)
        #expect(accepted.termsVersion == "2026-11-24")

        let legacy = try JSONDecoder().decode(
            CreatorAccess.self,
            from: Data(#"{"canUpload":true,"canCreateChannel":true}"#.utf8)
        )
        #expect(legacy.termsAccepted == nil)
        #expect(legacy.termsVersion == nil)
    }

    @Test func nativeAcceptCreatorTermsPostsVersionAndParses409() async throws {
        final class Recorder: @unchecked Sendable {
            var method: String?
            var path: String?
            var auth: String?
            var body: Data?
        }
        let recorder = Recorder()
        let session = StubURLProtocol.session { request in
            recorder.method = request.httpMethod
            recorder.path = request.url?.path
            recorder.auth = request.value(forHTTPHeaderField: "Authorization")
            if let body = request.httpBody {
                recorder.body = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                recorder.body = data
            }
            return (200, [:], Data(#"{"ok":true}"#.utf8))
        }
        let service = NativeStudioService(
            baseURL: URL(string: "https://videos.api.qa.alummahnow.net")!,
            accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]),
            session: session)
        try await service.acceptCreatorTerms(version: "2026-11-24")
        #expect(recorder.method == "POST")
        #expect(recorder.path == "/api/me/creator/terms")
        let token = recorder.auth?.split(separator: " ")
        #expect(token?.first == "Bearer")
        #expect(DeletionToken.accountID(of: String(token?.last ?? "")) == FixtureAccountService.creator.id)
        let sentJSON = try #require(
            recorder.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(sentJSON["version"] == "2026-11-24")

        // 409 terms_version_changed surfaces the server's currentVersion as a Refusal.
        let conflictSession = StubURLProtocol.session { _ in
            (
                409, ["Content-Type": "application/json"],
                Data(#"{"success":false,"code":"terms_version_changed","currentVersion":"2026-12-01"}"#.utf8)
            )
        }
        let conflictService = NativeStudioService(
            baseURL: URL(string: "https://videos.api.qa.alummahnow.net")!,
            accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]),
            session: conflictSession)
        do {
            try await conflictService.acceptCreatorTerms(version: "2026-11-24")
            Issue.record("Expected 409 terms_version_changed error")
        } catch let error as CoreError {
            #expect(error.refusal?.code == Refusal.termsVersionChanged)
            #expect(error.refusal?.currentVersion == "2026-12-01")
        }
    }
}

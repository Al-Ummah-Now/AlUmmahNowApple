import AUNCoreBridge
import AunCore
import Foundation
import Testing

@testable import AUNCoreKit

final class MemoryStorage: SecureStorage, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func get(key: String) throws -> Data? { lock.withLock { values[key] } }
    func set(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func delete(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    func list(prefix: String) throws -> [String] { lock.withLock { values.keys.filter { $0.hasPrefix(prefix) }.sorted() } }
}

struct CoreAccountServiceTests {
    private func service() throws -> CoreAccountService {
        try CoreAccountService(
            issuer: URL(string: "https://auth.qa.alummahnow.net/")!, clientID: "studio-client", storage: MemoryStorage())
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    @Test func signInUsesPKCEAndTheStudioRedirect() async throws {
        let request = try await service().beginSignIn(.standard)
        #expect(request.url.absoluteString.hasPrefix("https://auth.qa.alummahnow.net/authorize?"))
        #expect(request.callbackScheme == "alummahnow-studio")
        let items = query(request.url)
        #expect(items["client_id"] == "studio-client")
        #expect(items["redirect_uri"] == "alummahnow-studio://auth/callback")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"]?.isEmpty == false)
        #expect(items["state"]?.isEmpty == false)
        #expect(items["scope"]?.contains("offline_access") == true)
        #expect(items["prompt"] == nil)
    }

    @Test func addAccountUsesTheSameFreshSignIn() async throws {
        let service = try service()
        let first = try await service.beginSignIn(.addAccount)
        let second = try await service.beginSignIn(.addAccount)
        #expect(query(first.url)["state"] != query(second.url)["state"])
        #expect(query(first.url)["code_challenge"] != query(second.url)["code_challenge"])
    }

    @Test func aRedirectWithAnotherStateIsRefused() async throws {
        let service = try service()
        _ = try await service.beginSignIn(.standard)
        await #expect(throws: CoreError.self) {
            try await service.completeSignIn(redirect: URL(string: "alummahnow-studio://auth/callback?code=x&state=forged")!)
        }
        #expect(try await service.accounts().isEmpty)
    }

    @Test func noAccountMeansNoToken() async throws {
        let service = try service()
        #expect(try await service.activeAccount() == nil)
        #expect(try await service.accessToken() == nil)
    }

    @Test func errorsMapOntoTheBridge() {
        #expect(CoreError(AunError.Unauthorized(detail: "x")) == .signInRequired)
        #expect(CoreError(AunError.Forbidden(detail: "x")) == .forbidden)
        #expect(CoreError(AunError.Http(status: 503, code: nil, detail: "x")) == .http(status: 503))
        #expect(CoreError(AunError.Offline) == .offline)
        #expect(CoreError(AunError.Cancelled) == .cancelled)
    }

    @Test func environmentCarriesTheStudioClient() {
        let environment = AppEnvironment.fromInfoDictionary([
            "AUNAPIBaseURL": "https://videos.api.qa.alummahnow.net", "AUNEnvironment": "qa",
            "AUNAuthIssuer": "https://auth.qa.alummahnow.net", "AUNOAuthClientID": "abc",
        ])
        #expect(environment.oauthClientID == "abc")
        #expect(environment.authIssuer.host() == "auth.qa.alummahnow.net")
        let viewer = AppEnvironment.fromInfoDictionary([
            "AUNAPIBaseURL": "https://videos.api.qa.alummahnow.net", "AUNEnvironment": "qa",
            "AUNAuthIssuer": "http://auth.qa.alummahnow.net", "AUNOAuthClientID": "",
        ])
        #expect(viewer.oauthClientID == nil)
        #expect(viewer.authIssuer == AppEnvironment.qaAuthIssuer)
    }
}

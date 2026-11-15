import CryptoKit
import Foundation
import Testing

@testable import AUNCoreBridge

/// A fake App Attest: records the client data hashes it signs.
final class FakeAppAttest: AppAttesting, @unchecked Sendable {
    private let lock = NSLock()
    let isSupported: Bool
    private(set) var generated = 0
    private(set) var attested: [Data] = []
    private(set) var asserted: [Data] = []

    init(supported: Bool = true) { isSupported = supported }

    func generateKey() async throws -> String {
        lock.withLock {
            generated += 1
            return "key-\(generated)"
        }
    }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { attested.append(clientDataHash) }
        return Data("attestation-\(keyID)".utf8)
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { asserted.append(clientDataHash) }
        return Data("assertion-\(keyID)".utf8)
    }
}

/// A fake server for `/api/apps/attestation/*`, counting each route.
final class FakeAttestationServer: @unchecked Sendable {
    private let lock = NSLock()
    var enabled = true
    var off = false
    var unknownKeys: Set<String> = []
    var expiresAt = "2040-01-01T00:00:00.000Z"
    private(set) var hits: [String: Int] = [:]
    private(set) var bodies: [String: [String: String]] = [:]
    private var issued = 0

    func count(_ route: String) -> Int { lock.withLock { hits[route] ?? 0 } }
    func body(_ route: String) -> [String: String] { lock.withLock { bodies[route] ?? [:] } }

    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        let route = request.url!.path().replacingOccurrences(of: "/api/apps/attestation/", with: "")
        let body = (try? JSONDecoder().decode([String: String].self, from: StubURLProtocol.body(of: request))) ?? [:]
        return lock.withLock {
            hits[route, default: 0] += 1
            bodies[route] = body
            if off { return (404, [:], Data(#"{"success":false,"code":"attestation_off"}"#.utf8)) }
            switch route {
            case "config":
                return (
                    200, [:],
                    Data(
                        #"{"success":true,"result":{"apple":{"enabled":\#(enabled)},"android":{"enabled":false,"cloudProjectNumber":null}}}"#
                            .utf8)
                )
            case "challenge":
                issued += 1
                return (
                    200, [:],
                    Data(#"{"success":true,"result":{"challenge":"ch-\#(issued)","expiresAt":"2030-01-01T00:00:00Z"}}"#.utf8)
                )
            case "apple/assert" where unknownKeys.contains(body["keyId"] ?? ""):
                return (404, [:], Data(#"{"success":false,"code":"unknown_key"}"#.utf8))
            case "apple/register", "apple/assert":
                issued += 1
                return (
                    200, [:], Data(#"{"success":true,"result":{"proof":"proof-\#(issued)","expiresAt":"\#(expiresAt)"}}"#.utf8)
                )
            default:
                return (500, [:], Data())
            }
        }
    }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_900_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

struct AttestationTests {
    private let base = URL(string: "https://videos.api.qa.alummahnow.net")!

    private func service(
        _ server: FakeAttestationServer, attest: FakeAppAttest = FakeAppAttest(), keys: MemoryAttestationKeyStore = .init(),
        clock: TestClock = TestClock()
    ) -> NativeAttestationService {
        NativeAttestationService(
            baseURL: base, bundleID: "net.alummahnow.studio.qa", attest: attest, keys: keys,
            session: StubURLProtocol.session { server.handle($0) }, now: { clock.now })
    }

    private func sha256(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

    @Test func disabledConfigSendsNothingElse() async {
        let server = FakeAttestationServer()
        server.enabled = false
        let attest = FakeAppAttest()
        let service = service(server, attest: attest)
        #expect(await service.proof(account: "u1", fresh: false) == nil)
        #expect(await service.proof(account: "u1", fresh: true) == nil)
        #expect(server.count("config") == 1)  // cached for the hour
        #expect(server.count("challenge") == 0)
        #expect(attest.generated == 0)
    }

    @Test func attestationOffAnswerIsTreatedAsDisabled() async {
        let server = FakeAttestationServer()
        server.off = true
        let service = service(server)
        #expect(await service.proof(account: "u1", fresh: false) == nil)
        #expect(await service.proof(account: "u1", fresh: false) == nil)
        #expect(server.count("config") == 1)
    }

    @Test func unsupportedDeviceNeverCallsTheServer() async {
        let server = FakeAttestationServer()
        let service = service(server, attest: FakeAppAttest(supported: false))
        #expect(await service.proof(account: "u1", fresh: false) == nil)
        #expect(server.count("config") == 0)
    }

    @Test func registersOnceThenAssertsAndCachesPerAccount() async {
        let server = FakeAttestationServer()
        let attest = FakeAppAttest()
        let keys = MemoryAttestationKeyStore()
        let service = service(server, attest: attest, keys: keys)

        let first = await service.proof(account: "u1", fresh: false)
        #expect(first == "proof-2")
        #expect(attest.generated == 1)
        #expect(attest.attested == [sha256("ch-1")])
        #expect(keys.load() == "key-1")
        let register = server.body("apple/register")
        #expect(register["keyId"] == "key-1")
        #expect(register["challenge"] == "ch-1")
        #expect(register["bundleId"] == "net.alummahnow.studio.qa")
        #expect(register["attestation"] == Data("attestation-key-1".utf8).base64EncodedString())

        // Same account: the cached proof, no network.
        #expect(await service.proof(account: "u1", fresh: false) == first)
        #expect(server.count("challenge") == 1)

        // Another account: a new proof by assertion with the stored key.
        let second = await service.proof(account: "u2", fresh: false)
        #expect(second != nil && second != first)
        #expect(attest.generated == 1)
        #expect(attest.asserted == [sha256("ch-3")])
        #expect(server.body("apple/assert")["keyId"] == "key-1")
        #expect(server.body("apple/assert")["assertion"] == Data("assertion-key-1".utf8).base64EncodedString())

        // fresh: a new one even though one is cached.
        let renewed = await service.proof(account: "u1", fresh: true)
        #expect(renewed != first)
        #expect(server.count("apple/assert") == 2)
    }

    @Test func unknownKeyIsDroppedAndRegisteredAgain() async {
        let server = FakeAttestationServer()
        server.unknownKeys = ["old"]
        let attest = FakeAppAttest()
        let keys = MemoryAttestationKeyStore("old")
        let service = service(server, attest: attest, keys: keys)
        #expect(await service.proof(account: "u1", fresh: false) != nil)
        #expect(server.count("apple/assert") == 1)
        #expect(server.count("apple/register") == 1)
        #expect(keys.load() == "key-1")
    }

    @Test func proofIsRenewedFiveMinutesBeforeItExpires() async {
        let server = FakeAttestationServer()
        let clock = TestClock()
        server.expiresAt = clock.now.addingTimeInterval(3600).ISO8601Format()
        let service = service(server, clock: clock)
        let first = await service.proof(account: "u1", fresh: false)
        clock.advance(3600 - 301)
        #expect(await service.proof(account: "u1", fresh: false) == first)
        clock.advance(2)
        #expect(await service.proof(account: "u1", fresh: false) != first)
    }

    @Test func serverFailureGivesNilAndRetriesLater() async {
        let clock = TestClock()
        let service = NativeAttestationService(
            baseURL: base, bundleID: "b", attest: FakeAppAttest(), keys: MemoryAttestationKeyStore(),
            session: StubURLProtocol.session { _ in (503, [:], Data()) }, now: { clock.now })
        #expect(await service.proof(account: "u1", fresh: false) == nil)
    }
}

/// A proof provider that hands out numbered proofs and records the requests.
final class CountingProofs: NativeProofProviding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(account: String, fresh: Bool)] = []
    func proof(account: String, fresh: Bool) async -> String? {
        lock.withLock {
            calls.append((account, fresh))
            return "proof-\(calls.count)"
        }
    }
}

struct NativeProofHeaderTests {
    private let base = URL(string: "https://videos.api.qa.alummahnow.net")!
    private let proofRequired = Data(#"{"success":false,"code":"native_proof_required","error":"native_proof_required"}"#.utf8)

    private func client(_ proofs: CountingProofs?, _ handler: @escaping StubURLProtocol.Handler) -> StudioHTTPClient {
        StudioHTTPClient(
            baseURL: base, accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]),
            session: StubURLProtocol.session(handler: handler), proofs: proofs)
    }

    @Test func writesCarryTheAccountsProofReadsDoNot() async throws {
        let proofs = CountingProofs()
        let seen = Locked<[String?]>([])
        let client = client(proofs) { request in
            seen.mutate { $0.append(request.value(forHTTPHeaderField: StudioHTTPClient.proofHeader)) }
            return (200, [:], Data("{}".utf8))
        }
        try await client.sendRaw(.get, "/api/channels/access")
        try await client.sendRaw(.post, "/api/videos/bulk-delete", body: ["videoIds": ["v1"]])
        try await client.sendRaw(.patch, "/api/videos/v1", body: ["title": "x"])
        #expect(seen.value == [nil, "proof-1", "proof-2"])
        #expect(proofs.calls.map(\.account) == [FixtureAccountService.creator.id, FixtureAccountService.creator.id])
        #expect(proofs.calls.allSatisfy { !$0.fresh })
    }

    @Test func proofRequiredIsRetriedOnceWithAFreshProof() async throws {
        let proofs = CountingProofs()
        let attempts = Locked(0)
        let client = client(proofs) { _ in
            let attempt = attempts.mutate {
                $0 += 1; return $0
            }
            return attempt == 1 ? (403, [:], proofRequired) : (200, [:], Data("{}".utf8))
        }
        try await client.sendRaw(.post, "/api/posts", body: ["text": "x"])
        #expect(attempts.value == 2)
        #expect(proofs.calls.map(\.fresh) == [false, true])
    }

    @Test func secondProofRequiredIsForbiddenWithoutAThirdTry() async {
        let proofs = CountingProofs()
        let attempts = Locked(0)
        let client = client(proofs) { _ in
            attempts.mutate { $0 += 1 }
            return (403, [:], proofRequired)
        }
        await #expect(throws: CoreError.forbidden) { try await client.sendRaw(.post, "/api/posts", body: ["text": "x"]) }
        #expect(attempts.value == 2)
    }

    @Test func otherForbiddenAnswersAreNotRetried() async {
        let attempts = Locked(0)
        let client = client(CountingProofs()) { _ in
            attempts.mutate { $0 += 1 }
            return (403, [:], Data(#"{"success":false,"code":"not_owner"}"#.utf8))
        }
        await #expect(throws: CoreError.forbidden) { try await client.sendRaw(.post, "/api/posts", body: ["text": "x"]) }
        #expect(attempts.value == 1)
    }

    @Test func withoutAProviderNoHeaderAndNoRetry() async {
        let attempts = Locked(0)
        let client = client(nil) { request in
            #expect(request.value(forHTTPHeaderField: StudioHTTPClient.proofHeader) == nil)
            attempts.mutate { $0 += 1 }
            return (403, [:], proofRequired)
        }
        await #expect(throws: CoreError.forbidden) { try await client.sendRaw(.post, "/api/posts", body: ["text": "x"]) }
        #expect(attempts.value == 1)
    }
}

/// A value shared with `@Sendable` stub handlers.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    @discardableResult func mutate<T>(_ change: (inout Value) -> T) -> T { lock.withLock { change(&stored) } }
}

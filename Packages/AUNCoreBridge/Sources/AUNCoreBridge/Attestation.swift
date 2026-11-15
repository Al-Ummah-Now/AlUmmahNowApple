import CryptoKit
import Foundation
import Security

#if os(iOS)
    import DeviceCheck
#endif

/// The device's App Attest service, behind a protocol so tests use a fake one.
public protocol AppAttesting: Sendable {
    var isSupported: Bool { get }
    /// A new hardware key; returns its key id (base64, as Apple returns it).
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// Where the attested key id is kept between launches (the Keychain in the apps).
public protocol AttestationKeyStoring: Sendable {
    func load() -> String?
    func save(_ keyID: String)
    func remove()
}

/// A proof for `X-AUN-Native-Proof`. A proof counts only for the signed-in account that first sends it, so it is
/// fetched per account. Never throws: nil means "send the request without the header" (the server decides).
public protocol NativeProofProviding: Sendable {
    /// The cached proof for `account`, or a new one when `fresh` or when none is cached.
    func proof(account: String, fresh: Bool) async -> String?
}

/// No attestation (tvOS, macOS, fixtures, devices without App Attest).
public struct UnsupportedAppAttest: AppAttesting {
    public init() {}
    public var isSupported: Bool { false }
    public func generateKey() async throws -> String { throw CoreError.forbidden }
    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { throw CoreError.forbidden }
    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data { throw CoreError.forbidden }
}

#if os(iOS)
    /// `DCAppAttestService`. Needs the `com.apple.developer.devicecheck.appattest-environment` entitlement, which only
    /// the signed QA and Release builds carry; unsigned and simulator builds report `isSupported == false`.
    public struct DeviceAppAttest: AppAttesting {
        public init() {}
        public var isSupported: Bool { DCAppAttestService.shared.isSupported }
        public func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
        public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
            try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
        }
        public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
            try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
        }
    }
#endif

/// The key id in the Keychain, this device only (an App Attest key never leaves the device).
public struct KeychainAttestationKeyStore: AttestationKeyStoring {
    private let service: String
    private let account = "app-attest-key-id"

    public init(service: String = "net.alummahnow.app-attest") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ keyID: String) {
        remove()
        var item = query
        item[kSecValueData as String] = Data(keyID.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { AUNLog.network.error("App Attest key id not saved: \(status)") }
    }

    public func remove() { SecItemDelete(query as CFDictionary) }
}

/// Key ids held in memory, for tests and previews.
public final class MemoryAttestationKeyStore: AttestationKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keyID: String?
    public init(_ keyID: String? = nil) { self.keyID = keyID }
    public func load() -> String? { lock.withLock { keyID } }
    public func save(_ keyID: String) { lock.withLock { self.keyID = keyID } }
    public func remove() { lock.withLock { keyID = nil } }
}

/// App Attest against api-videos (`/api/apps/attestation/*`, NAT-REL). Off until videos admin → Mobile apps turns
/// Apple attestation on: while `GET /config` says disabled (or answers 404 `attestation_off`) it sends nothing more.
/// First use on a device: generateKey → attestKey → `apple/register`; afterwards generateAssertion → `apple/assert`
/// (an `unknown_key` 404 drops the key and registers again). Every failure is logged and gives nil.
public actor NativeAttestationService: NativeProofProviding {
    struct Envelope<T: Decodable>: Decodable { let result: T }
    struct Config: Decodable {
        struct Apple: Decodable { let enabled: Bool }
        let apple: Apple
    }
    struct Challenge: Decodable { let challenge: String }
    struct Proof: Decodable {
        let proof: String
        let expiresAt: String
    }
    struct ErrorBody: Decodable { let code: String? }

    enum Failure: Error {
        case off
        case unknownKey
        case http(Int, String?)
    }

    /// How long the config answer is kept (the contract's once per launch, at most an hour).
    static let configLifetime: TimeInterval = 3600
    /// A failed config read is retried after this, so an outage does not slow every write.
    static let failureLifetime: TimeInterval = 300
    /// Proofs are renewed this long before they expire.
    static let renewMargin: TimeInterval = 300

    private let baseURL: URL
    private let bundleID: String
    private let attest: any AppAttesting
    private let keys: any AttestationKeyStoring
    private let session: URLSession
    private let now: @Sendable () -> Date

    private var enabled: (value: Bool, until: Date)?
    private var proofs: [String: (proof: String, until: Date)] = [:]
    private var pending: [String: Task<String?, Never>] = [:]

    public init(
        baseURL: URL, bundleID: String, attest: any AppAttesting, keys: any AttestationKeyStoring = KeychainAttestationKeyStore(),
        session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.bundleID = bundleID
        self.attest = attest
        self.keys = keys
        self.session = session
        self.now = now
    }

    public func proof(account: String, fresh: Bool) async -> String? {
        guard attest.isSupported else { return nil }
        if !fresh, let cached = proofs[account], cached.until > now() { return cached.proof }
        if let running = pending[account] { return await running.value }
        let task = Task { await self.obtain(account: account) }
        pending[account] = task
        let proof = await task.value
        pending[account] = nil
        return proof
    }

    private func obtain(account: String) async -> String? {
        do {
            guard try await isEnabled() else { return nil }
            let proof = try await newProof()
            let expires = Self.date(proof.expiresAt) ?? now().addingTimeInterval(Self.renewMargin * 2)
            proofs[account] = (proof.proof, expires.addingTimeInterval(-Self.renewMargin))
            return proof.proof
        } catch Failure.off {
            enabled = (false, now().addingTimeInterval(Self.configLifetime))
            return nil
        } catch {
            AUNLog.network.error("App Attest proof failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func isEnabled() async throws -> Bool {
        if let enabled, enabled.until > now() { return enabled.value }
        do {
            let config = try await call("GET", "/api/apps/attestation/config", as: Config.self)
            enabled = (config.apple.enabled, now().addingTimeInterval(Self.configLifetime))
            return config.apple.enabled
        } catch Failure.off {
            throw Failure.off
        } catch {
            enabled = (false, now().addingTimeInterval(Self.failureLifetime))
            throw error
        }
    }

    private func newProof() async throws -> Proof {
        if let keyID = keys.load() {
            do {
                return try await assertion(keyID)
            } catch Failure.unknownKey {
                keys.remove()
            }
        }
        return try await register()
    }

    private func challenge() async throws -> (text: String, hash: Data) {
        let challenge = try await call("POST", "/api/apps/attestation/challenge", body: [String: String](), as: Challenge.self)
        return (challenge.challenge, Data(SHA256.hash(data: Data(challenge.challenge.utf8))))
    }

    private func register() async throws -> Proof {
        let keyID = try await attest.generateKey()
        let (challenge, hash) = try await challenge()
        let attestation = try await attest.attestKey(keyID, clientDataHash: hash)
        let proof = try await call(
            "POST", "/api/apps/attestation/apple/register",
            body: [
                "keyId": keyID, "attestation": attestation.base64EncodedString(), "challenge": challenge, "bundleId": bundleID,
            ], as: Proof.self)
        keys.save(keyID)
        return proof
    }

    private func assertion(_ keyID: String) async throws -> Proof {
        let (challenge, hash) = try await challenge()
        let assertion = try await attest.generateAssertion(keyID, clientDataHash: hash)
        return try await call(
            "POST", "/api/apps/attestation/apple/assert",
            body: ["keyId": keyID, "assertion": assertion.base64EncodedString(), "challenge": challenge, "bundleId": bundleID],
            as: Proof.self)
    }

    private func call<T: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil, as: T.Type)
        async throws -> T
    {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.code
            if status == 404 && code == "attestation_off" { throw Failure.off }
            if status == 404 && code == "unknown_key" { throw Failure.unknownKey }
            throw Failure.http(status, code)
        }
        return try JSONDecoder().decode(Envelope<T>.self, from: data).result
    }

    static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

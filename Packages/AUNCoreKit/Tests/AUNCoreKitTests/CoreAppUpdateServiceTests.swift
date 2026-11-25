import AUNCoreBridge
import Foundation
import Testing

@testable import AUNCoreKit
@testable import AunCore

/// Studio for Mac's update check over the real aun-core binding (wiki AUN-APP-UPDATES §3.5, §4.1.1).
struct CoreAppUpdateServiceTests {
    private func identity(_ source: AppInstallSource = .managed) -> AppUpdateIdentity {
        AppUpdateIdentity(app: "studio", platform: "macos", version: "1.2.0.0", source: source, beta: false, arch: "arm64")
    }

    private static func body(_ action: String, status: String = "recommended", minimum: String = "0.0.0") -> Data {
        Data(
            """
            {"update":{"enabled":true,"status":"\(status)","minimumVersion":"\(minimum)","latestVersion":"1.3.0",
            "action":"\(action)","available":true,"checkHours":6,"url":"https://example.com/elsewhere","storeUrl":"https://example.com/store",
            "manifestUrl":"https://github.com/Al-Ummah-Now/AlUmmahNowApple/releases/download/v1.3.0/app-release.json","tag":"v1.3.0"}}
            """.utf8)
    }

    private func check(
        _ data: Data, source: AppInstallSource = .managed, rootKeys: [String] = AppUpdateKeys.rootKeys
    ) async throws -> AppUpdatePrompt? {
        let suite = "net.alummahnow.tests.core-updates.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let service = try CoreAppUpdateService(
            identity: identity(source), apiBaseURL: try #require(URL(string: "https://videos.api.qa.alummahnow.net")),
            rootKeys: rootKeys, session: FixedAnswerProtocol.session(data),
            defaults: try #require(UserDefaults(suiteName: suite)))
        return try await service.check().prompt
    }

    /// A list the root key didn't sign throws here: such a build must never ship.
    @Test func theCompiledInKeyListVerifiesUnderTheCompiledInRootKey() throws {
        let list = try #require(AppUpdateKeys.bundled("update-keys.json"))
        let signature = try #require(AppUpdateKeys.bundled("update-keys.json.sig"))
        let checker = try UpdateChecker(
            repo: CoreAppUpdateService.repo, rootKeys: AppUpdateKeys.rootKeys, installedVersion: "1.2.0.0", betaChannel: false,
            stateJson: nil, bundledKeyList: list, bundledKeyListSig: signature)
        #expect(checker.stateJson().contains("\"serial\":1"))
        #expect(throws: (any Error).self) {
            try UpdateChecker(
                repo: CoreAppUpdateService.repo, rootKeys: AppUpdateKeys.rootKeys, installedVersion: "1.2.0.0",
                betaChannel: false,
                stateJson: nil, bundledKeyList: list + " ", bundledKeyListSig: signature)
        }
    }

    /// AlUmmahNowCore spec/app-updates/signed-vector.json, copied: accepted as it is, refused with one change.
    @Test func theSharedSignedVectorVerifiesAndAChangeIsRefused() throws {
        struct Vector: Decodable {
            let rootPublicKey: String
            let keyList: String
            let keyListSig: String
            let manifest: String
            let manifestSig: String
        }
        let url = try #require(Bundle.module.url(forResource: "app-update-signed-vector", withExtension: "json"))
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        let checker = try UpdateChecker(
            repo: "AlUmmahNowTools", rootKeys: [vector.rootPublicKey], installedVersion: "2026.11.22", betaChannel: false,
            stateJson: nil, bundledKeyList: vector.keyList, bundledKeyListSig: vector.keyListSig)
        let good = checker.verifyManifest(manifest: Data(vector.manifest.utf8), signature: vector.manifestSig, tag: "v2026.11.23")
        #expect(good.refused == nil)
        let changed = vector.manifest.replacing("Faster", with: "Slower")
        let bad = checker.verifyManifest(manifest: Data(changed.utf8), signature: vector.manifestSig, tag: "v2026.11.23")
        #expect(bad.refused == "bad_signature")
    }

    @Test func downloadOpensTheFixedPageNeverTheAnswers() async throws {
        #expect(try await check(Self.body("download"))?.action == .download)
        // This build can't install: the same page
        #expect(try await check(Self.body("install"))?.action == .download)
        #expect(CoreAppUpdateService.downloadPage.absoluteString == "https://github.com/Al-Ummah-Now/AlUmmahNowApple/releases")
    }

    @Test func installNeedsARootKeyADirectBuildAndOurOwnManifestAddress() async throws {
        let prompt = try #require(try await check(Self.body("install"), source: .direct))
        let manifest = "https://github.com/Al-Ummah-Now/AlUmmahNowApple/releases/download/v1.3.0/app-release.json"
        #expect(prompt.action == .install(manifest: try #require(URL(string: manifest)), tag: "v1.3.0"))
        let text = try #require(String(bytes: Self.body("install"), encoding: .utf8))
        let elsewhere = Data(text.replacing("AlUmmahNowApple/releases", with: "Other/releases").utf8)
        #expect(try await check(elsewhere, source: .direct)?.action == .download)
        #expect(try await check(Self.body("install"), source: .direct, rootKeys: [])?.action == .download)
    }

    @Test func aNoticeAnswerIsNothingForABuildWithARootKey() async throws {
        #expect(try await check(Self.body("notice")) == nil)
        #expect(try await check(Self.body("notice", status: "required", minimum: "1.3.0"))?.kind == .requiredSoon)
        let keyless = try #require(try await check(Self.body("notice"), rootKeys: []))
        #expect(keyless.action == .download)
        #expect(try await check(Self.body("notice", status: "required", minimum: "1.3.0"), rootKeys: [])?.kind == .forced)
    }

    private func service(
        suite: String, _ data: Data, status: Int = 200, version: String = "1.2.0.0"
    ) throws -> CoreAppUpdateService {
        var identity = self.identity()
        identity.version = version
        return try CoreAppUpdateService(
            identity: identity, apiBaseURL: try #require(URL(string: "https://videos.api.qa.alummahnow.net")),
            session: FixedAnswerProtocol.session(data, status: status), defaults: try #require(UserDefaults(suiteName: suite)))
    }

    @Test func aClosedNoticeStaysClosedAndAMinimumAlreadySeenHoldsOfflineAcrossLaunches() async throws {
        let suite = "net.alummahnow.tests.core-updates.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let first = try service(suite: suite, Self.body("download"))
        #expect(await first.offlinePrompt() == nil)
        #expect(try await first.check().prompt?.version == "1.3.0")
        await first.dismiss(version: "1.3.0")
        #expect(try await service(suite: suite, Self.body("download")).check().prompt == nil)
        // Below a minimum nothing can be closed
        let required = Self.body("download", status: "required", minimum: "1.3.0")
        #expect(try await service(suite: suite, required).check().prompt?.kind == .forced)
        let offline = try service(suite: suite, Data())
        #expect(await offline.offlinePrompt() == AppUpdatePrompt(kind: .requiredSoon))
        #expect(await (try service(suite: suite, Data(), version: "1.3.0.0")).offlinePrompt() == nil)
    }

    @Test func notesAndMessageNeedBothLanguages() async throws {
        func body(_ notes: String, _ message: String) throws -> Data {
            let text = try #require(String(bytes: Self.body("download", status: "required", minimum: "1.3.0"), encoding: .utf8))
            return Data(
                text.replacing("\"checkHours\":6", with: "\"checkHours\":6,\"notes\":\(notes),\"message\":\(message)").utf8)
        }
        let both = try #require(try await check(try body(#"{"en":"Faster.","ar":"أسرع."}"#, #"{"en":"Too old.","ar":"قديم."}"#)))
        #expect(both.notes == AppUpdateText(en: "Faster.", ar: "أسرع."))
        #expect(both.message == AppUpdateText(en: "Too old.", ar: "قديم."))
        let one = try #require(try await check(try body(#"{"en":"Faster.","ar":""}"#, "null")))
        #expect(one.notes == nil)
        #expect(one.message == nil)
    }

    @Test func aServerErrorOrAGarbledAnswerThrowsAndChangesNothing() async throws {
        let suite = "net.alummahnow.tests.core-updates.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let failing = try service(suite: suite, Self.body("download"), status: 503)
        await #expect(throws: CoreError.http(status: 503)) { try await failing.check() }
        for text in ["[]", "{}", #"{"update":{"enabled":true,"minimumVersion":7}}"#] {
            let garbled = try service(suite: suite, Data(text.utf8))
            await #expect(throws: CoreError.decoding) { try await garbled.check() }
        }
        #expect(UserDefaults(suiteName: suite)?.string(forKey: "AUNCoreAppUpdateState") == nil)
    }
}

/// Answers every request with the same bytes.
private final class FixedAnswerProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: (Data, Int)] = [:]

    static func session(_ data: Data, status: Int = 200) -> URLSession {
        let token = UUID().uuidString
        lock.withLock { answers[token] = (data, status) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixedAnswerProtocol.self]
        config.httpAdditionalHeaders = ["X-Stub-Token": token]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "X-Stub-Token") ?? ""
        guard let url = request.url, let (data, status) = Self.lock.withLock({ Self.answers[token] }),
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

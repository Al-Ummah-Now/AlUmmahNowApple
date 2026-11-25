import Foundation
import StoreKit
import Testing

@testable import AUNCoreBridge

/// App updates (wiki AUN-APP-UPDATES): the shared version cases, and what a store build shows.
struct AppUpdateTests {
    private struct Cases: Decodable {
        struct Case: Decodable {
            let a: String
            let b: String
            let sign: Int
            init(from decoder: any Decoder) throws {
                var c = try decoder.unkeyedContainer()
                a = try c.decode(String.self)
                b = try c.decode(String.self)
                sign = try c.decode(Int.self)
            }
        }
        let cases: [Case]
        let valid: [String]
        let invalid: [String]
    }

    /// AlUmmahNowCore spec/app-updates/versions.json, copied: the server and aun-core run the same cases.
    @Test func versionsCompareAsTheServerDoes() throws {
        let url = try #require(Bundle.module.url(forResource: "app-update-versions", withExtension: "json"))
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
        #expect(cases.cases.count > 10)
        for item in cases.cases {
            let (a, b) = (try #require(AppVersion(item.a)), try #require(AppVersion(item.b)))
            #expect((a < b ? -1 : b < a ? 1 : 0) == item.sign, "\(item.a) \(item.b)")
            #expect((a == b) == (item.sign == 0))
            if a == b { #expect(a.hashValue == b.hashValue) }
        }
        for text in cases.valid { #expect(AppVersion(text) != nil, "\(text)") }
        for text in cases.invalid + ["", "1.2.٣", "1234567.0.0"] { #expect(AppVersion(text) == nil, "\(text)") }
    }

    @Test func theInstalledVersionCarriesTheRebuildNumber() {
        #expect(AppVersion.installed(shortVersion: "1.2.3", build: "1020302") == "1.2.3.2")
        #expect(AppVersion.installed(shortVersion: "1.2.3", build: "1020300") == "1.2.3.0")
        #expect(AppVersion.installed(shortVersion: "0.0.41", build: "0.41.1") == "0.0.41.0")
        #expect(AppVersion.installed(shortVersion: "0.0.41", build: nil) == "0.0.41.0")
        #expect(AppVersion.installed(shortVersion: "dev", build: "1") == nil)
        #expect(AppVersion.installed(shortVersion: nil, build: "1") == nil)
    }

    private func answer(_ fields: [String: Any]) throws -> AppUpdateAnswer {
        var all: [String: Any] = [
            "enabled": true, "status": "recommended", "minimumVersion": "0.0.0", "latestVersion": "1.3.0",
            "storeUrl": "https://apps.apple.com/app/id1", "action": "store", "available": true,
        ]
        for (key, value) in fields { all[key] = value }
        return try JSONDecoder().decode(AppUpdateAnswer.self, from: JSONSerialization.data(withJSONObject: all))
    }

    private func decide(
        _ fields: [String: Any] = [:], source: AppInstallSource = .appStore, installed: String = "1.2.0.0"
    ) throws -> AppUpdatePrompt? {
        var state = StoreUpdateDecider.State()
        return StoreUpdateDecider(source: source, installed: installed).decide(try answer(fields), state: &state)
    }

    @Test func aNewerVersionInTheStoreIsANoticeThatOpensIt() throws {
        let prompt = try #require(try decide(["notes": ["en": "Faster.", "ar": "أسرع."]]))
        #expect(prompt.kind == .notice)
        #expect(prompt.version == "1.3.0")
        #expect(prompt.notes?.ar == "أسرع.")
        #expect(prompt.action == .store(try #require(URL(string: "https://apps.apple.com/app/id1"))))
        #expect(try decide(source: .testFlight)?.action == .store(try #require(URL(string: "itms-beta://"))))
    }

    @Test func nothingShowsWhenThereIsNothingToGet() throws {
        #expect(try decide(["enabled": false]) == nil)
        #expect(try decide(["status": "ok"]) == nil)
        #expect(try decide(["available": false]) == nil)
        #expect(try decide(["available": NSNull()]) == nil)
        #expect(try decide(["latestVersion": NSNull()]) == nil)
        #expect(try decide(installed: "1.3.0.0") == nil)
        #expect(try decide(installed: "1.4.0.0") == nil)
    }

    /// A store build opens its store and nothing else, whatever the server says.
    @Test func otherActionsAndOtherPagesAreRefused() throws {
        for action in ["install", "download", "notice", "run"] { #expect(try decide(["action": action]) == nil, "\(action)") }
        for page in [
            "http://apps.apple.com/app/id1", "https://apps.apple.com.example.com/app/id1", "https://example.com/app",
            "https://user@apps.apple.com/app/id1", "https://apps.apple.com:8443/app/id1", "javascript:alert(1)", "",
        ] { #expect(try decide(["storeUrl": page]) == nil, "\(page)") }
        #expect(try decide(source: .managed) == nil)
        #expect(try decide(source: .direct) == nil)
    }

    @Test func belowTheMinimumTheScreenNeedsAnUpdateThatHelps() throws {
        let message = ["en": "Too old.", "ar": "قديم."]
        let forced = try #require(try decide(["status": "required", "minimumVersion": "1.3.0", "message": message]))
        #expect(forced.kind == .forced)
        #expect(forced.message?.en == "Too old.")
        // Not in the store yet, or in the store but still below the minimum: the app keeps working behind the bar
        let unhelpful: [[String: Any]] = [
            ["available": false], ["latestVersion": "1.2.5"], ["action": "notice"], ["storeUrl": NSNull()],
        ]
        for fields in unhelpful {
            let soon = try #require(try decide(["status": "required", "minimumVersion": "1.3.0"].merging(fields) { $1 }))
            #expect(soon.kind == .requiredSoon)
            #expect(soon.action == nil)
        }
    }

    @Test func offlineHoldsOnlyAMinimumAlreadySeen() throws {
        let decider = StoreUpdateDecider(source: .appStore, installed: "1.2.0.0")
        var state = StoreUpdateDecider.State()
        #expect(decider.offline(state) == nil)
        _ = decider.decide(try answer(["status": "required", "minimumVersion": "1.3.0"]), state: &state)
        #expect(decider.offline(state)?.kind == .requiredSoon)
        #expect(StoreUpdateDecider(source: .appStore, installed: "1.3.0.0").offline(state) == nil)
        _ = decider.decide(try answer(["enabled": false]), state: &state)
        #expect(decider.offline(state) == nil)
    }

    @Test func anUnreadableAnswerOrVersionShowsNothing() throws {
        #expect(try decide(["minimumVersion": "soon"]) == nil)
        #expect(try decide(installed: "dev") == nil)
        #expect(throws: (any Error).self) { try answer(["notes": "text"]) }
    }

    @Test func storeEnvironmentsNameTheSource() {
        #expect(StoreInstallSource.source(environment: .production) == .appStore)
        #expect(StoreInstallSource.source(environment: .sandbox) == .testFlight)
        #expect(StoreInstallSource.source(environment: .xcode) == nil)
    }

    private func service(
        defaults: String = "net.alummahnow.tests.updates.\(UUID().uuidString)", _ handler: @escaping StubURLProtocol.Handler
    ) throws -> NativeAppUpdateService {
        NativeAppUpdateService(
            identity: AppUpdateIdentity(app: "viewer", platform: "ios", version: "1.2.0.0", source: .appStore, beta: false),
            apiBaseURL: try #require(URL(string: "https://videos.api.qa.alummahnow.net")),
            session: StubURLProtocol.session(handler: handler), defaults: try #require(UserDefaults(suiteName: defaults)))
    }

    private static let body = Data(
        #"""
        {"update":{"enabled":true,"status":"recommended","minimumVersion":"0.0.0","latestVersion":"1.3.0","action":"store",
        "storeUrl":"https://apps.apple.com/app/id1","available":true,"checkHours":100,"future":{"x":1}}}
        """#.utf8)

    @Test func asksWithTheVersionAndSourceAndNothingAboutThePerson() async throws {
        let checked = try await service { request in
            #expect(request.url?.path() == "/api/v1/app-config")
            let items = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(Set(items.map(\.name)) == ["platform", "app", "version", "channel", "source"])
            #expect(items.first { $0.name == "version" }?.value == "1.2.0.0")
            #expect(items.first { $0.name == "source" }?.value == "appstore")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, [:], Self.body)
        }.check()
        #expect(checked.enabled)
        #expect(checked.prompt?.kind == .notice)
        #expect(checked.checkHours == 48)
    }

    @Test func aClosedNoticeStaysClosedForThatVersionAcrossLaunches() async throws {
        let suite = "net.alummahnow.tests.updates.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let first = try service(defaults: suite) { _ in (200, [:], Self.body) }
        #expect(try await first.check().prompt != nil)
        await first.dismiss(version: "1.3.0")
        let second = try service(defaults: suite) { _ in (200, [:], Self.body) }
        #expect(try await second.check().prompt == nil)
        let newer = Data(try #require(String(bytes: Self.body, encoding: .utf8)).replacing("1.3.0", with: "1.3.1").utf8)
        let third = try service(defaults: suite) { _ in (200, [:], newer) }
        #expect(try await third.check().prompt?.version == "1.3.1")
    }

    @Test func aServerErrorThrowsAndChangesNothing() async throws {
        let failing = try service { _ in (503, [:], Data()) }
        await #expect(throws: CoreError.http(status: 503)) { try await failing.check() }
        let garbled = try service { _ in (200, [:], Data("[]".utf8)) }
        await #expect(throws: CoreError.decoding) { try await garbled.check() }
        #expect(await failing.offlinePrompt() == nil)
    }
}

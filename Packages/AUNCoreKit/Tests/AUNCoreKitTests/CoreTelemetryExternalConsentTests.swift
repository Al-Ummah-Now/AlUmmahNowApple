import AUNCoreBridge
import Foundation
import Observation
import Testing

@testable import AUNCoreKit

@Suite("CoreTelemetryExternalConsent")
struct CoreTelemetryExternalConsentTests {
    @Test("Preserves valid RFC 3986 URLs and HTTP status lines")
    func preservesValidRFC3986URLs() {
        let preserved = [
            "https://videos.api.alummahnow.net/v1/items",
            "https://[2001:db8::1]/v1/items",
            "https://example.com/a(b)/items",
            "https://example.com/a(b;c)/items",
            "open(https://example.com/a(b)/items)",
            "Failure: Main.ts:42",
            "https://example.com/a'b/items",
            "https://foo!bar.example/api",
            "https://one;two.example/api",
            "https://example.com/v1;version=2/items",
            "git+http2://example.com/repo",
            "profile://example.com/repo",
            "https://[::1]:8443/api",
            "a123456789012345678901234567890123://example.com/repo",
            "HTTP/1.1 503 Service Unavailable",
        ]
        for item in preserved {
            #expect(CoreTelemetryService.sanitizeLocalPaths(item) == item)
        }
        #expect(CoreTelemetryService.sanitizeLocalPaths("https://[:::]/api") != "https://[:::]/api")
        #expect(CoreTelemetryService.sanitizeLocalPaths("https://bad%zz/api") != "https://bad%zz/api")
    }

    @Test("Scrubs query strings, embedded schemes, local paths, emails, and bearer tokens")
    func scrubsQueriesPathsEmailsAndTokens() {
        let cases: [(String, String)] = [
            ("https://example.com/api;file:///storage/emulated/0/Secret.mov", "https://example.com/api;[redacted-path]"),
            ("https://example.com/api;C://Secret/Acquisition.mov", "https://example.com/api;[redacted-path]"),
            ("https://example.com/?path=/Users/alice/Secret.mov", "https://example.com/?[redacted]"),
            ("https://example.com/api?path=/storage/emulated/0/Secret.mov", "https://example.com/api?[redacted]"),
            ("https://example.com/api?source=%2FUsers%2Falice%2FPrivateProject", "https://example.com/api?[redacted]"),
            ("https://example.com/api?token=abc[secret]&next=private", "https://example.com/api?[redacted]"),
            ("https://example.com/api?q=(PrivateProject)", "https://example.com/api?[redacted]"),
            ("(https://example.com/api?q=(PrivateProject))", "(https://example.com/api?[redacted])"),
            ("https://example.com/api#first,PrivateProject", "https://example.com/api#[redacted]"),
            ("https://example.com/users/alice@example.com", "https://example.com/users/[redacted-email]"),
            ("https://example.com/users/alice%40example.com", "https://example.com/users/[redacted-email]"),
            ("https://example.com/users/alice%team@example.com", "https://example.com/users/[redacted-email]"),
            ("alice%notes@example.com", "[redacted-email]"),
            ("https://example.com/?token=abc{Secret}xyz", "https://example.com/?[redacted]"),
            ("(https://example.com/?q=secret).", "(https://example.com/?[redacted])."),
            ("file:///private/(https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("file:///private/Project Folder/(https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("file:///private/Project Folder/( https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("file:///private/Project Folder/ (https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("\"file:///private/My Folder (https://Secret/Acquisition.mov)\"", "\"[redacted-path]"),
            ("\"file:///a.mov\" (https://example.com/api)", "\"[redacted-path]\" (https://example.com/api)"),
            ("file:///private/Folder/ https://example.com/api", "[redacted-path] https://example.com/api"),
            ("file:///private/My\u{00A0}Acquisition", "[redacted-path]"),
            ("file:///a.mov and ( https://example.com/api)", "[redacted-path] ( https://example.com/api)"),
            ("file:///a.mov and (((https://example.com/api)))", "[redacted-path] (((https://example.com/api)))"),
            ("file:// Secret Acquisition", "[redacted-path]"),
            ("file:///storage/emulated/0/Secret.mov and (https://example.com/api)", "[redacted-path] (https://example.com/api)"),
            ("https://example.com/ (https://other.com/api)", "https://example.com/ (https://other.com/api)"),
            ("/private/Project Folder/(https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("/private/Project Folder/( https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("(relative/Secret.mov and https://example.com/api)", "([redacted-path] https://example.com/api)"),
            ("Bearer abcdefg", "Bearer [redacted]"),
            ("file:///storage/emulated/0/https://Secret/Acquisition.mov", "[redacted-path]"),
            ("(/storage/emulated/0/Secret.mov and https://example.com/api)", "([redacted-path] https://example.com/api)"),
            ("file:///storage/emulated/0/Secret.mov and https://example.com/api", "[redacted-path] https://example.com/api"),
            (
                "Failed for alice@example.com with Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig",
                "Failed for [redacted-email] with Bearer [redacted]"
            ),
            ("https://example.com/api,open(C://Secret/Acquisition.mov)", "https://example.com/api,open([redacted-path])"),
            ("(https://example.com)(private/Secret.mov)", "(https://example.com)([redacted-path])"),
            ("https://example.com(/Users/alice/Secret.mov)", "https://example.com([redacted-path])"),
            ("open(/Volumes/Secret/Acquisition.mov) Player.open() + 42", "open([redacted-path]) Player.open() + 42"),
            ("open Secret.mov from https://example.com/api", "open [redacted-path] from https://example.com/api"),
            ("Secret Project.mov (missing)", "[redacted-path] (missing)"),
            ("open Secret.mov:42", "open [redacted-path]:42"),
            ("https://example.com/api,private/Secret.mov", "https://example.com/api,[redacted-path]"),
            ("Secret.Final.mov", "[redacted-path]"),
            ("Could not find file Secret.2026", "Could not find file [redacted-path]"),
        ]
        for (input, expected) in cases {
            #expect(CoreTelemetryService.sanitizeLocalPaths(input) == expected)
        }
    }

    @Test("Queued flush re-checks UserDefaults via live(defaults:) before entering native flush")
    func queuedFlushReChecksLiveDefaultsBeforeNativeFlush() async throws {
        let suiteName = "net.alummahnow.telemetry.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "AUNTelemetryEnabled")

        let env = AppEnvironment(name: "test", apiBaseURL: URL(string: "http://127.0.0.1:1")!)
        let service = try #require(
            CoreTelemetryService.live(
                environment: env,
                defaults: defaults,
                userAgentPrefix: "AlUmmahNowTest",
                bufferFilename: "test-\(UUID().uuidString).json"
            ) as? CoreTelemetryService
        )
        defer { _ = service.setConsent(.off) }

        service.track("screen_view", properties: ["screen": "home"])
        #expect(service.pendingCount == 1)

        let flagLock = NSLock()
        nonisolated(unsafe) var flushEntered = false
        nonisolated(unsafe) let defaultsRef = defaults
        service.beforeFlushExecuteForTesting = {
            defaultsRef.set(false, forKey: "AUNTelemetryEnabled")
        }
        service.flushOverrideForTesting = {
            flagLock.withLock { flushEntered = true }
        }

        await service.flush()

        #expect(!flagLock.withLock { flushEntered })
        #expect(service.consent == .off)
        #expect(service.pendingCount == 0)
    }

    @Test("Late revoked flush purge failure notifies Observation subscribers for lastPurgeFailed")
    func lateRevokedFlushPurgeFailureNotifiesObservation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aun-tel-obs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bufferPath = dir.appendingPathComponent("telemetry-buffer.json").path
        let gate = TelemetryFlushSlotGate()

        let service = try CoreTelemetryService(
            platform: "macos",
            appVersion: "1.0.0",
            osVersion: "macOS 15.0",
            deviceClass: "desktop",
            locale: "en",
            videosAPIBaseURL: nil,
            userAgent: "AlUmmahNowMac/1.0.0",
            bufferPath: bufferPath,
            initialEnabled: true
        )
        service.flushOverrideForTesting = { await gate.enter() }

        let flushTask = Task { await service.flush() }
        await gate.waitForSlot(0)

        #expect(service.setConsent(.off))
        #expect(!service.lastPurgeFailed)

        let observedLock = NSLock()
        nonisolated(unsafe) var notified = false
        withObservationTracking {
            _ = service.lastPurgeFailed
        } onChange: {
            observedLock.withLock { notified = true }
        }

        // Make parent dir read-only after planting a late buffer so releaseInFlightFlush fails cleanup.
        try Data("{\"late\":true}".utf8).write(to: URL(fileURLWithPath: bufferPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

        gate.releaseSlot(0)
        await flushTask.value

        #expect(service.lastPurgeFailed)
        #expect(observedLock.withLock { notified })
    }
}

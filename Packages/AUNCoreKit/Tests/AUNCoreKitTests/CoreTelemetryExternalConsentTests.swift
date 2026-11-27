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
            ("https://example.com/users/alice@example.com", "https://[redacted-email]"),
            ("https://example.com/users/alice%40example.com", "https://[redacted-email]"),
            ("https://example.com/users/alice%team@example.com", "https://[redacted-email]"),
            ("https://example.com/users/alice/bob@example.org", "https://[redacted-email]"),
            ("alice%notes@example.com", "[redacted-email]"),
            ("https://example.com/?token=abc{Secret}xyz", "https://example.com/?[redacted]"),
            ("(https://example.com/?q=secret).", "(https://example.com/?[redacted])."),
            ("file:///private/(https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("file:///private/Project Folder/(https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("file:///private/Project Folder/( https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("file:///private/Project Folder/ (https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("\"file:///private/My Folder (https://Secret/Acquisition.mov)\"", "\"[redacted-path]\""),
            ("\"file:///private/Client \\\"Internal\\\" Acquisition\"", "\"[redacted-path]\""),
            ("\"file:///a.mov\" (https://example.com/api)", "\"[redacted-path]\" (https://example.com/api)"),
            ("file:///private/Folder/ https://example.com/api", "[redacted-path] https://example.com/api"),
            ("file:///private/My\u{00A0}Acquisition", "[redacted-path]"),
            ("\"file:///a.mov\" and ( https://example.com/api)", "\"[redacted-path]\" and ( https://example.com/api)"),
            ("\"file:///a.mov\" and (((https://example.com/api)))", "\"[redacted-path]\" and (((https://example.com/api)))"),
            ("file:// Secret Acquisition", "[redacted-path]"),
            ("file:///private/Secret\u{001E}Acquisition", "[redacted-path]"),
            (
                "file:///a.mov; https://example.com/ (https://other.example/api)",
                "[redacted-path] https://example.com/ (https://other.example/api)"
            ),
            (
                "file:///a.mov; https://example.com/ /private/foo(https://Secret/Acquisition.mov)",
                "[redacted-path] https://example.com/ [redacted-path]"
            ),
            ("file://   https://example.com/api", "[redacted-path]   https://example.com/api"),
            ("file:///storage/emulated/0/Secret.mov and (https://example.com/api)", "[redacted-path]"),
            ("https://example.com/ (https://other.com/api)", "https://example.com/ (https://other.com/api)"),
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

    @Test("Scrubs spaced local paths and sentinels while preserving protocol tokens and fractions")
    func scrubsSpacedPathsAndPreservesProtocols() {
        let cases: [(String, String)] = [
            ("/private/Project Folder/(https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("/private/Project Folder/( https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("/private/foo(https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("/private/Client Files (https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("/private/Transfer to (https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("relative/Client Files (https://Secret/Acquisition.mov)", "[redacted-path]"),
            ("path=/private/Client Files (https://Secret/Acquisition.mov)", "path=[redacted-path]"),
            ("/private/Secret\u{001E}https://Secret/Acquisition.mov", "[redacted-path]"),
            ("/private/Secret\u{001E}Acquisition", "[redacted-path]"),
            ("/private/Secret^Acquisition", "[redacted-path]"),
            ("TLS/1.3(https://example.com/api)", "TLS/1.3(https://example.com/api)"),
            ("HTTP/2(https://example.com/api)", "HTTP/2(https://example.com/api)"),
        ]
        for (input, expected) in cases {
            #expect(CoreTelemetryService.sanitizeLocalPaths(input) == expected)
        }
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("\"relative/My Clip.mov\" and (https://example.com/api)")
                .contains("https://example.com/api")
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("progress 1/2 (https://example.com/api)")
                == "progress 1/2 (https://example.com/api)"
        )
        #expect(CoreTelemetryService.sanitizeLocalPaths("progress 1/2.") == "progress 1/2.")
        #expect(CoreTelemetryService.sanitizeLocalPaths("progress (1/2.)") == "progress (1/2.)")
        #expect(CoreTelemetryService.sanitizeLocalPaths("progress (1/2 )") == "progress (1/2 )")
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("progress (1/2...) (https://example.com/api)")
                == "progress (1/2...) (https://example.com/api)"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/a(b/c)")
                == "https://example.com/a(b/c)"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/a(b(c/d))")
                == "https://example.com/a(b(c/d))"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/a(/storage/PrivateProject)")
                == "https://example.com/a([redacted-path])"
        )
    }

    @Test("Scrubs quoted file URIs, apostrophes, and backslash paths")
    func scrubsQuotedFileURIsAndBackslashPaths() {
        let extraCases: [(String, String)] = [
            ("'file:///tmp/O'Brien Secret'", "'[redacted-path]"),
            ("'file:///tmp/O'Brien Secret", "'[redacted-path]"),
            ("'file:///tmp/James' Private Name'", "'[redacted-path]"),
            ("'file:///tmp/Project'2 Secret'", "'[redacted-path]"),
            ("\"file:///tmp/Secret\" progress 1/2", "\"[redacted-path]\" progress 1/2"),
            ("'file:///tmp/O' Connor Private", "'[redacted-path]"),
            ("'file:///tmp/O' Connor Private'", "'[redacted-path]"),
            ("'file:///tmp/O'Connor' Private'Collection Plan", "'[redacted-path]"),
            ("'file:///tmp/Artists' Private 'Collection'", "'[redacted-path]"),
            ("'file:///tmp/Artists' Private 'Collection", "'[redacted-path]"),
            ("'file:///tmp/O' Connor Private (https://private.example/Acquisition.mov)", "'[redacted-path]"),
            ("input'file:///tmp/O' Connor Private https://private.example/Acquisition.mov", "input'[redacted-path]"),
            ("input'/tmp/O' Connor Private https://private.example/Acquisition.mov", "input'[redacted-path]"),
            ("'(/tmp/Client) Acquisition Plan'", "'([redacted-path]"),
            ("' (/tmp/Client) Acquisition Plan'", "' ([redacted-path]"),
            ("\" (/tmp/Client) Acquisition Plan\"", "\" ([redacted-path]"),
            ("\"My (/tmp/Client) Acquisition Plan\"", "\"My ([redacted-path]"),
            ("\"(relative/Client) Acquisition Plan\"", "\"([redacted-path]"),
            (
                "Failed for 李@example.com, محمد@مثال.مصر, user@bücher.example, 「李·明@例え.jp」, "
                    + "李@例え.xn--p1ai, 李!明@example.com, mary'ann@example.com, 李·明@example.com, "
                    + "'o'brien@example.com, {@example.com, 李，@example.com, 李，明@example.com, "
                    + "\"李·明\"@example.com, \"john doe\"@example.com, user@[192.0.2.1], user@[IPv6:2001:db8::1]",
                "Failed for [redacted-email], [redacted-email], [redacted-email], 「[redacted-email]」, "
                    + "[redacted-email], [redacted-email], [redacted-email], [redacted-email], "
                    + "'[redacted-email], [redacted-email], [redacted-email], [redacted-email], "
                    + "[redacted-email], [redacted-email], [redacted-email], [redacted-email]"
            ),
            ("status 'ready' (https://example.com/api)", "status 'ready' (https://example.com/api)"),
            ("/tmp/Private\u{2028}Acquisition Plan", "[redacted-path]"),
            (
                "Failed for \"Private Name user@[IPv6:2001:db8::1]\"@example.com, \"john@doe.example\"@example.com, "
                    + "\"alice@example.com private\"@example.org, \"john\r\n doe\"@example.com, "
                    + "alice=tag@example.com, user@localhost, alice@intranet, "
                    + "\"Private Name alice/bob\"@example.com, alice@x, alice@3com",
                "Failed for [redacted-email], [redacted-email], [redacted-email], "
                    + "[redacted-email], [redacted-email], [redacted-email], [redacted-email], "
                    + "[redacted-email], [redacted-email], [redacted-email]"
            ),
            ("alice/bob@example.com", "[redacted-path]"),
            ("file \"private name\"@localhost", "file [redacted-email]"),
            ("document \"private name\"%40intranet", "document [redacted-email]"),
            ("'Private.qzx'2 Acquisition.qzx'", "[redacted-path]"),
            ("'Studio 2's Acquisition.qzx'", "[redacted-path]"),
        ]
        for (input, expected) in extraCases {
            #expect(CoreTelemetryService.sanitizeLocalPaths(input) == expected)
        }
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("'Studio 2' Acquisition.qzx'")
                == "[redacted-path]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("'Studio 'Private Acquisition.qzx'")
                == "[redacted-path]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("status \"ready; detail \"Private Project.qzx\"")
                == "status \"ready; detail [redacted-path]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("private]folder\\secret")
                == "[redacted-path]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("progress 1/2. (https://example.com/api)")
                == "progress 1/2. (https://example.com/api)"
        )
        #expect(CoreTelemetryService.sanitizeLocalPaths("opening 1/2.mov") == "opening [redacted-path]")
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("opening\u{00A0}Acquisition.qzx")
                == "opening\u{00A0}[redacted-path]"
        )
    }

    @Test("Scrubs IDN email dots, Unicode scalars, and filename-like email local parts")
    func scrubsIDNEmailDotsScalarsAndFilenameEmails() {
        let cases: [(String, String)] = [
            ("\"Private Name https://example.com/api?q=secret\\\" tail\"@example.com", "[redacted-email]"),
            ("alice@example.123😀", "alice@example.123😀"),
            ("alice@😀", "alice@😀"),
            ("alice@x😀", "[redacted-email]😀"),
            ("alice@example.𐐷", "[redacted-email]"),
            ("alice@123。example.com", "[redacted-email]"),
            ("alice@example。com", "[redacted-email]"),
            ("alice@example．com", "[redacted-email]"),
            ("alice@example｡com", "[redacted-email]"),
            ("alice@example.com。", "[redacted-email]。"),
            ("alice.txt@example.com", "[redacted-email]"),
            ("alice.txt+tag@example.com", "[redacted-email]"),
            ("Failed for alice.txt@example.com", "Failed for [redacted-email]"),
            ("Private Project.pdf and alice.txt@example.com", "[redacted-path] and [redacted-email]"),
            ("file alice.txt@example.com", "file [redacted-path]"),
            ("file alice.txt@localhost", "file [redacted-email]"),
            ("file Private Project alice.txt@example.com", "file [redacted-path]"),
            ("'alice.txt'@example.com", "[redacted-path]"),
            ("alice@internal.pdf.example.org", "[redacted-email]"),
            ("alice.txt@example.zip.private", "[redacted-email]"),
        ]
        for (input, expected) in cases {
            #expect(CoreTelemetryService.sanitizeLocalPaths(input) == expected)
        }
        let repeatedFilenameEmails = String(repeating: "alice.txt@example.org ", count: 5_000)
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(repeatedFilenameEmails)
                == String(repeating: "[redacted-email] ", count: 5_000)
        )
    }

    @Test("Scrubs structured, nested, folded, and standalone Authorization credentials")
    func scrubsStructuredNestedFoldedAndStandaloneAuthCredentials() {
        let cases: [(String, String)] = [
            ("Authorization: Basic YWxpY2U6c2VjcmV0", "Authorization: Basic [redacted]"),
            ("Proxy-Authorization: Basic YWxpY2U6c2VjcmV0", "Proxy-Authorization: Basic [redacted]"),
            ("Authorization: Digest username=\"alice\", response=\"deadbeef\"", "Authorization: Digest [redacted]"),
            ("{\"Authorization\": \"Basic YWxpY2U6c2VjcmV0\"}", "{\"Authorization\": \"Basic [redacted]\"}"),
            ("{\"Authorization\":\"opaqueSecret123\"}", "{\"Authorization\":\"[redacted]\"}"),
            (
                "{\"Proxy-Authorization\":\"Digest username=alice, response=deadbeef\"}",
                "{\"Proxy-Authorization\":\"Digest [redacted]\"}"
            ),
            (
                "{\"Authorization\":\"Digest username=\\\"alice\\\", response=\\\"deadbeef\\\"\"}",
                "{\"Authorization\":\"Digest [redacted]\"}"
            ),
            (
                "{\"Authorization\":\"Bearer testSecret\",\"status\":401}",
                "{\"Authorization\":\"Bearer [redacted]\",\"status\":401}"
            ),
            (
                "{\"Authorization\":[\"Bearer testSecret\"],\"status\":401}",
                "{\"Authorization\":[\"Bearer [redacted]\"],\"status\":401}"
            ),
            (
                "{\"Authorization\":[[\"firstValue\"],\"opaqueSecret123\"]}",
                "{\"Authorization\":[[\"[redacted]\"],\"[redacted]\"]}"
            ),
            ("Authorization: [opaqueSecret123]", "Authorization: [[redacted]]"),
            ("Authorization: [firstValue]\r\n\topaqueSecret123", "Authorization: [[redacted]]\r\n\t[redacted]"),
            ("Authorization: \"firstValue\"\r\n\topaqueSecret123", "Authorization: \"[redacted]\"\r\n\t[redacted]"),
            ("Authorization: \"firstValue\" opaqueSecret123", "Authorization: \"[redacted]\" [redacted]"),
            ("Authorization: \"firstValue\" x opaqueSecret123", "Authorization: \"[redacted]\" [redacted]"),
            (
                "{\"Authorization\": \"opaqueSecret123\", \"status\": \"safe\"}",
                "{\"Authorization\": \"[redacted]\", \"status\": \"safe\"}"
            ),
            ("Authorization: [firstValue]\r\nNextHeader: safe", "Authorization: [[redacted]]\r\nNextHeader: safe"),
            ("{\n  \"Authorization\": \"opaqueSecret123\"\n  }", "{\n  \"Authorization\": \"[redacted]\"\n  }"),
            ("Authorization:\r\n\topaqueSecret123", "Authorization:\r\n\t[redacted]"),
            ("Authorization: Digest username=\"alice\",\r\n response=\"deadbeef\"", "Authorization: Digest [redacted]"),
            ("Authorization:\r\nNextHeader: safe", "Authorization:\r\nNextHeader: safe"),
            (
                "{\"\\u0041uthorization\":\"opaqueSecret123\",\"status\":401}",
                "{\"Authorization\":\"[redacted]\",\"status\":401}"
            ),
            ("{\"Authoriz\\u0061tion\":\"opaqueSecret123\"}", "{\"Authorization\":\"[redacted]\"}"),
            (
                "{\"Authorization\": \n \"opaqueSecret123\",\"status\":401}",
                "{\"Authorization\": \n \"[redacted]\",\"status\":401}"
            ),
            ("\"Authorization\": opaqueSecret123 nextPart", "\"Authorization\": [redacted]"),
            ("Authorization: opaqueSecret123 nextPart", "Authorization: [redacted]"),
            ("Authorization: X-Secret secondword", "Authorization: [redacted]"),
            ("Basic YTpi", "Basic [redacted]"),
            ("Basic YTpi.", "Basic [redacted]."),
            ("Basic YTo=", "Basic [redacted]"),
            ("Basic YTp=", "Basic YTp="),
            ("Basic Og==", "Basic [redacted]"),
            ("Basic ajpqampq", "Basic [redacted]"),
            ("BASIC YWxpY2U6c2VjcmV0", "BASIC [redacted]"),
            ("Basic YWxpY2U6Y2Fm6Q==", "Basic [redacted]"),
            ("Basic YWJjZGU=", "Basic YWJjZGU="),
            ("Basic YTpiCQ", "Basic YTpiCQ"),
            ("Basic auth failed", "Basic auth failed"),
        ]
        for (input, expected) in cases {
            #expect(CoreTelemetryService.sanitizeLocalPaths(input) == expected)
        }
    }
}

@Suite("CoreTelemetryLifecycle")
struct CoreTelemetryLifecycleTests {

    @Test("Scrubs quoted/wrapped embedded URLs and scales linearly on adversarial inputs")
    func scrubsQuotedEmbeddedURLsAndScalesLinearly() {
        let privateCases = [
            "opening \"1/2 (https://private.example/Acquisition.mov)\"",
            "opening \"HTTP/2 (https://private.example/Acquisition.mov)\"",
            "opening \"My Project/Clip https://private.example/Acquisition.mov\"",
            "opening \"(relative/My Clip.mov) https://private.example/Acquisition.mov\"",
            "opening \"/tmp/Project 'draft' (https://private.example/Acquisition.mov)\"",
            "opening /tmp/Project 'draft' (https://private.example/Acquisition.mov)",
            "opening \"relative/My's (https://private.example/Acquisition.mov)\"",
            "opening relative/My(1) (https://private.example/Acquisition.mov)",
            "'relative/Artists' Private (https://private.example/Acquisition.mov)'",
        ]
        for input in privateCases {
            #expect(!CoreTelemetryService.sanitizeLocalPaths(input).contains("private.example"))
        }
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "opening \"relative/My's Clip.mov\" (https://example.com/api)"
            ).contains("https://example.com/api")
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("can't reach https://example.com/api")
                == "can't reach https://example.com/api"
        )
        let longAlpha = String(repeating: "a", count: 100_000)
        #expect(CoreTelemetryService.sanitizeLocalPaths(longAlpha) == longAlpha)
        let repeatedKeywords = String(repeating: "open ", count: 20_000) + "."
        #expect(CoreTelemetryService.sanitizeLocalPaths(repeatedKeywords) == repeatedKeywords)
        let repeatedQuotes = String(repeating: "'a ", count: 20_000) + "."
        #expect(CoreTelemetryService.sanitizeLocalPaths(repeatedQuotes) == repeatedQuotes)
        let repeatedEquals = String(repeating: "=", count: 50_000)
        #expect(CoreTelemetryService.sanitizeLocalPaths(repeatedEquals) == repeatedEquals)
        let leadingSpaces = String(repeating: " ", count: 50_000) + "x.qzx"
        #expect(CoreTelemetryService.sanitizeLocalPaths(leadingSpaces) == leadingSpaces)
        let repeatedBrackets = String(repeating: "https://[", count: 20_000)
        #expect(CoreTelemetryService.sanitizeLocalPaths(repeatedBrackets).contains("[redacted-path]"))
        let longQuotedFile = "'" + String(repeating: "b", count: 100_000) + ".pdf'"
        #expect(CoreTelemetryService.sanitizeLocalPaths(longQuotedFile) == "[redacted-path]")
        let repeatedClosers = String(repeating: "x.qzx' ", count: 20_000)
        #expect(CoreTelemetryService.sanitizeLocalPaths(repeatedClosers) == repeatedClosers)
        let embeddedQueries = "/tmp;" + String(repeating: "https://host?x;", count: 5_000)
        #expect(CoreTelemetryService.sanitizeLocalPaths(embeddedQueries) == "[redacted-path]")
        let longWindowsPath = "C:\\Private" + String(repeating: " folder", count: 20_000)
        #expect(CoreTelemetryService.sanitizeLocalPaths(longWindowsPath) == "[redacted-path]")
        let longFractionURLs = String(repeating: "1", count: 50_000) + "/" + String(repeating: "https://a;", count: 2_000)
        #expect(CoreTelemetryService.sanitizeLocalPaths(longFractionURLs) == "[redacted-path]")
    }

    @Test("Startup live(defaults:) clears stored AUNTelemetryEnabled when initial consent activation fails")
    func liveStartupConsentFailureResetsStoredPreference() throws {
        let suiteName = "net.alummahnow.telemetry.startupfail.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "AUNTelemetryEnabled")

        let env = AppEnvironment(name: "test", apiBaseURL: URL(string: "http://127.0.0.1:1")!)
        // Passing a directory path as the buffer filename forces native buffer persistence to fail on startup enable.
        let service = CoreTelemetryService.live(
            environment: env,
            defaults: defaults,
            userAgentPrefix: "AlUmmahNowTest",
            bufferFilename: ""
        )
        #expect(service.consent == .off)
        #expect(!defaults.bool(forKey: "AUNTelemetryEnabled"))
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

    @Test("addBreadcrumb category and reportCrash kind scrub PII before native persistence")
    func breadcrumbCategoryAndCrashKindScrubPII() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aun-tel-cat-pii-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bufferPath = dir.appendingPathComponent("telemetry-buffer.json").path

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
        service.addBreadcrumb(category: "alice@example.com", message: "Opening /Users/alice/Private/video.mp4")
        service.reportCrash(kind: "bob@example.com", message: "Failed to read /Users/alice/Secret.mov")
        let bufText = try String(contentsOfFile: bufferPath, encoding: .utf8)
        #expect(!bufText.contains("alice@example.com"))
        #expect(!bufText.contains("bob@example.com"))
        #expect(!bufText.contains("/Users/alice"))
        #expect(bufText.contains("[redacted-email]"))
    }
}

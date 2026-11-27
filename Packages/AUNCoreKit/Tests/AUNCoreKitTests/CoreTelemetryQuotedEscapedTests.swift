import Testing

@testable import AUNCoreKit

@Suite("CoreTelemetryQuotedEscapedTests")
struct CoreTelemetryQuotedEscapedTests {
    @Test("Scrubs JSON-embedded auth headers, escaped tokens, quoted emails, and spaced/angle URLs")
    func scrubsJsonEmbeddedAuthEscapedEmailsAndSpacedUrls() {
        let cases: [(String, String)] = [
            ("[\"alice\\u0040exa\\u0301mple.com ok\"]", "[\"[redacted-email] ok\"]"),
            ("{\"detail\":\"alice@exa\\u0301mple.test failed\"}", "{\"detail\":\"[redacted-email] failed\"}"),
            ("{\"detail\":\"\\\"Jane Doe\\\"@example.test failed\"}", "{\"detail\":\"[redacted-email] failed\"}"),
            (
                "{\"detail\":\"\\u0022Jane Doe\\u0022\\u0040exa\\u0301mple.test failed\"}",
                "{\"detail\":\"[redacted-email] failed\"}"
            ),
            (
                "[\"see \\u003chttps://example.com/api?token=first secondSecret\\u003e public\"]",
                "[\"see \\u003chttps://example.com/api?[redacted]\\u003e public\"]"
            ),
            (
                "{\"detail\":\"<https://example.test/webhook/SECRET TAIL>\"}",
                "{\"detail\":\"<https://example.test/webhook/[redacted]>\"}"
            ),
            (
                "{\"detail\":\"see <https://example.test/webhook/SECRET TAIL> public\"}",
                "{\"detail\":\"see <https://example.test/webhook/[redacted]> public\"}"
            ),
            (
                "{\"detail\":\"see \\u003chttps://example.test/webhook/SECRET TAIL\\u003e public\"}",
                "{\"detail\":\"see \\u003chttps://example.test/webhook/[redacted]\\u003e public\"}"
            ),
            (
                "{\"message\":\"Authorization: Bearer secret\",\"status\":\"ok\"}",
                "{\"message\":\"Authorization: Bearer [redacted]\",\"status\":\"ok\"}"
            ),
            (
                "{\"message\":\"Authorization:\\u0020Bearer\\u0020secret\",\"status\":\"ok\"}",
                "{\"message\":\"Authorization:\\u0020Bearer [redacted]\",\"status\":\"ok\"}"
            ),
            (
                "{\"message\":\"Authorization: Bearer secret\\nX-Public: ok\",\"status\":\"ok\"}",
                "{\"message\":\"Authorization: Bearer [redacted]\\nX-Public: ok\",\"status\":\"ok\"}"
            ),
            ("{\"message\":\"Bearer\\u0020secret\"}", "{\"message\":\"Bearer [redacted]\"}"),
            ("{\"message\":\"Bearer\\tsecret\"}", "{\"message\":\"Bearer [redacted]\"}"),
            ("{\"message\":\"Bearer\\u00A0secret\"}", "{\"message\":\"Bearer [redacted]\"}"),
            ("{\"message\":\"Basic\\u0020dXNlcjpwYXNz\"}", "{\"message\":\"Basic [redacted]\"}"),
            (
                "{\"message\":\"https://example.com/path name?token=private\"}",
                "{\"message\":\"https://example.com/path name?[redacted]\"}"
            ),
            (
                "{\"message\":\"https://example.com/path\\u0020name?token=private\"}",
                "{\"message\":\"https://example.com/path\\u0020name?[redacted]\"}"
            ),
            (
                "{\"message\":\"see https://example.com/public Why did it fail?\"}",
                "{\"message\":\"see https://example.com/public Why did it fail?\"}"
            ),
            (
                "{\"message\":\"see https://example.com/public issue #123\"}",
                "{\"message\":\"see https://example.com/public issue #123\"}"
            ),
            ("\"Authorization\\u003a secret\"", "\"Authorization\\u003a [redacted]\""),
            ("\"Authorization\\u003dsecret\"", "\"Authorization\\u003d[redacted]\""),
            ("headers=\"Authorization\\u003a opaqueSecret123\"", "headers=\"Authorization\\u003a [redacted]\""),
            (
                "headers=\"Authorization\\u003d opaqueSecret123\" status=ok",
                "headers=\"Authorization\\u003d [redacted]\" status=ok"
            ),
        ]
        for (input, expected) in cases {
            #expect(CoreTelemetryService.sanitizeLocalPaths(input) == expected)
        }
    }

    @Test("Scales linearly on unclosed angles/spaced hashes and sanitizes serialized property keys and values")
    func scalesLinearlyAndSanitizesPropertyKeysAndValues() {
        let repeatedAngles = String(repeating: "<https://example.test/webhooks/token ", count: 500)
        let expectedAngles = String(repeating: "<https://example.test/webhooks/[redacted] ", count: 500)
        #expect(CoreTelemetryService.sanitizeLocalPaths(repeatedAngles) == expectedAngles)
        let spacedHashes =
            "\"" + String(repeating: " ", count: 2000) + "https://example.test/path "
            + String(repeating: "# ", count: 2000) + "\""
        #expect(CoreTelemetryService.sanitizeLocalPaths(spacedHashes) == spacedHashes)
        let props = CoreTelemetryService.serializeProperties([
            "detail": "Authorization: Bearer secret",
            "path": "/Users/Alice/Secret.mov",
            "/Users/Alice/Acquisition.mov": "1",
            "Authorization": "opaqueSecret123",
            "screen": "home",
        ])
        #expect(props != nil)
        #expect(props?.contains("secret") == false)
        #expect(props?.contains("Alice") == false)
        #expect(props?.contains("Acquisition") == false)
        #expect(props?.contains("\"[redacted-path]\":\"1\"") == true)
        #expect(props?.contains("\"detail\":\"Authorization: Bearer [redacted]\"") == true)
        #expect(props?.contains("\"path\":\"[redacted-path]\"") == true)
        #expect(props?.contains("\"Authorization\":\"[redacted]\"") == true)
        #expect(props?.contains("\"screen\":\"home\"") == true)
    }
}

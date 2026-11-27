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
        ]
        for (input, expected) in cases {
            #expect(CoreTelemetryService.sanitizeLocalPaths(input) == expected)
        }
    }

    @Test("Redacts escaped auth separators, cookies, basic splits, and inner escaped bearer/path boundaries")
    func redactsEscapedAuthSeparatorsCookiesAndBearerBoundaries() {
        let cases: [(String, String)] = [
            ("\"Authorization\\u003a secret\"", "\"Authorization\\u003a [redacted]\""),
            ("\"Authorization\\u003dsecret\"", "\"Authorization\\u003d[redacted]\""),
            ("headers=\"Authorization\\u003a opaqueSecret123\"", "headers=\"Authorization\\u003a [redacted]\""),
            (
                "headers=\"Authorization\\u003d opaqueSecret123\" status=ok",
                "headers=\"Authorization\\u003d [redacted]\" status=ok"
            ),
            ("received (\"Authorization\\u003a opaqueSecret123\")", "received (\"Authorization\\u003a [redacted]\")"),
            ("Authorization\\u003a opaqueSecret123", "[redacted-path]"),
            ("{\"msg\":\"Basic YWI6\\u00632VjcmV0\"}", "{\"msg\":\"Basic [redacted]\"}"),
            (
                "{\"m\":\"literal=\\\"test\\\\stuff\\\"tail\",\"next\":1}",
                "{\"m\":\"literal=\\\"[redacted-path]\\\"tail\",\"next\":1}"
            ),
            (
                "{\"m\":\"{\\\"path\\\":\\\"/Users/Alice/Secret.mov\\\"}\",\"next\":1}",
                "{\"m\":\"{\\\"path\\\":\\\"[redacted-path]\\\"}\",\"next\":1}"
            ),
            (
                "received \"Authorizatio\\u006e: opaqueSecret123\"",
                "received \"Authorizatio\\u006e: [redacted]\""
            ),
            ("Cookie: session=opaqueSecret123", "Cookie: [redacted]"),
            ("Set-Cookie: session=opaqueSecret123; HttpOnly\r\nNext: ok", "Set-Cookie: [redacted]\r\nNext: ok"),
            (
                "{\"Cooki\\u0065\":\"session=opaqueSecret123\",\"status\":\"ok\"}",
                "{\"Cookie\":\"[redacted]\",\"status\":\"ok\"}"
            ),
            (
                "{\"m\":\"\\\"Bearer opaqueSecret123\\\"tail\",\"next\":1}",
                "{\"m\":\"\\\"Bearer [redacted]\\\"tail\",\"next\":1}"
            ),
            (
                "{\"m\":\"Bearer secret\\nX-Public: ok\"}",
                "{\"m\":\"Bearer [redacted]\\nX-Public: ok\"}"
            ),
            ("{\"Cookie \":\"session=opaqueSecret123\"}", "{\"Cookie \":\"[redacted]\"}"),
            ("[[\"Cookie\",\"session=opaqueSecret123\"]]", "[[\"Cookie\",\"[redacted]\"]]"),
            ("[[\"Authorization\",\"opaqueSecret123\"]]", "[[\"Authorization\",\"[redacted]\"]]"),
            ("[\"Authorization\",\"Cookie\",\"Accept\"]", "[\"Authorization\",\"Cookie\",\"Accept\"]"),
            ("{\\\"Authorization\\\":\\\"opaqueSecret123\\\"}", "{\\\"Authorization\\\":\\\"[redacted]\\\"}"),
            ("{\\\"Cookie\\\":\\\"opaqueSecret123\\\"}", "{\\\"Cookie\\\":\\\"[redacted]\\\"}"),
            (
                "{\"m\":\"auth = {\\\"a\\\":1,\\\"Cookie\\\":\\\"opaqueSecret123\\\"}; next\",\"next\":1}",
                "{\"m\":\"auth = {\\\"a\\\":1,\\\"Cookie\\\":\\\"[redacted]\\\"}; next\",\"next\":1}"
            ),
            (
                "{\"m\":\"Bearer \\\"opaqueSecret123\\\"tail\",\"next\":1}",
                "{\"m\":\"Bearer \\\"[redacted]\\\"tail\",\"next\":1}"
            ),
            ("{\"a\":\"Bearer \",\"b\":\"safe\"}", "{\"a\":\"Bearer \",\"b\":\"safe\"}"),
            (
                "{\"m\":\"literal=\\\"file:///tmp/private.mov\\\"tail\",\"next\":1}",
                "{\"m\":\"literal=\\\"[redacted-path]\\\"tail\",\"next\":1}"
            ),
            ("{\"Cookie\\t\":\"opaqueSecret123\"}", "{\"Cookie\":\"[redacted]\"}"),
            ("[[\"Cookie\\t\",\"opaqueSecret123\"]]", "[[\"Cookie\",\"[redacted]\"]]"),
            ("{\\\"Authorization\\\":[123456789]}", "{\\\"Authorization\\\":[\\\"[redacted]\\\"]}"),
            ("{\\\"Authorization\\\":123456789,\\\"next\\\":1}", "{\\\"Authorization\\\":\\\"[redacted]\\\",\\\"next\\\":1}"),
            (
                "{\\\"Authorization\\\":{\\\"token\\\":\\\"secret\\\"},\\\"next\\\":1}",
                "{\\\"Authorization\\\":\\\"[redacted]\\\",\\\"next\\\":1}"
            ),
        ]
        for (input, expected) in cases {
            #expect(CoreTelemetryService.sanitizeLocalPaths(input) == expected)
        }
        #expect(CoreTelemetryService.sanitizeLocalPaths("Bearer " + String(repeating: "A", count: 10000)) == "Bearer [redacted]")
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
            "/Users/Bob/Merger.mov": "2",
            "Authorization": "opaqueSecret123",
            "Cookie": "session=opaqueSecret123",
            "Set-Cookie": "sid=opaqueSecret456",
            "screen": "home",
        ])
        #expect(props != nil)
        #expect(props?.contains("secret") == false)
        #expect(props?.contains("session=") == false)
        #expect(props?.contains("Alice") == false)
        #expect(props?.contains("Bob") == false)
        #expect(props?.contains("Acquisition") == false)
        #expect(props?.contains("Merger") == false)
        #expect(props?.contains("\"[redacted-path]\":\"1\"") == true)
        #expect(props?.contains("\"[redacted-path]#2\":\"2\"") == true)
        #expect(props?.contains("\"detail\":\"Authorization: Bearer [redacted]\"") == true)
        #expect(props?.contains("\"path\":\"[redacted-path]\"") == true)
        #expect(props?.contains("\"Authorization\":\"[redacted]\"") == true)
        #expect(props?.contains("\"Cookie\":\"[redacted]\"") == true)
        #expect(props?.contains("\"Set-Cookie\":\"[redacted]\"") == true)
        #expect(props?.contains("\"screen\":\"home\"") == true)
        var manyColliding: [String: String] = [:]
        manyColliding.reserveCapacity(5000)
        for idx in 0..<5000 { manyColliding["/home/alice/private-\(idx)"] = "\(idx)" }
        let manyJson = CoreTelemetryService.serializeProperties(manyColliding)
        #expect(manyJson != nil)
        #expect(manyJson?.contains("alice") == false)
        #expect(manyJson?.contains("\"[redacted-path]#5000\":") == true)
    }
}

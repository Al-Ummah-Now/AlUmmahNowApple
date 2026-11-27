import AUNCoreKit
import Foundation
import Testing

@Suite("CoreTelemetryURLContinuationSanitizer")
struct CoreTelemetryURLContinuationTests {
    @Test("Handles quoted webhook groups, brace filenames, and linear nested parens")
    func handlesQuotedWebhookGroupsBraceFilenamesAndLinearNestedParens() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api{tag:\"value)\"}?token=opaqueSecret123")
                == "https://example.com/api{tag:\"value)\"}?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken{tag:\"first opaqueSecret123\"}")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken{tag:'first opaqueSecret123'}")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api{tag:'value)'}?token=opaqueSecret123")
                == "https://example.com/api{tag:'value)'}?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "https://example.com/api{url:\"see https://other.com/x?token=opaqueSecret123\"}?outer=value"
            ) == "https://example.com/api{url:\"see https://other.com/x?[redacted]\"}?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "https://example.com/api{url:\"see https://other.com/x?token=opaqueSecret123\"}"
            ) == "https://example.com/api{url:\"see https://other.com/x?[redacted]\"}"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "https://example.com/api{url:'see https://other.com/x?token=opaqueSecret123'}?outer=value"
            ) == "https://example.com/api{url:'see https://other.com/x?[redacted]'}?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "https://example.test/webhook/fakeToken('a)first opaqueSecret123')"
            ) == "https://example.test/webhook/[redacted]"
        )
        let repeatedEquals = Array(repeating: "https://a.test/x{a:\"https://b.test/x\"}", count: 500).joined(separator: "=")
        #expect(CoreTelemetryService.sanitizeLocalPaths(repeatedEquals) == repeatedEquals)
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "https://example.test/webhook/fakeToken{tag:\"a)opaqueSecret123\"}suffixSecret"
            ) == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken{abc://opaqueSecret123}")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/users/{Secret.mov}?token=opaqueSecret123")
                == "https://example.com/users/[redacted-path]}?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "https://example.com/api{url:\"https://other.com/x,public?token=opaqueSecret123\"}"
            ) == "https://example.com/api{url:\"https://other.com/x,public?[redacted]\"}"
        )
        let nestedParens =
            "https://example.com/a" + String(repeating: "(", count: 500) + String(repeating: "b/", count: 500)
            + String(repeating: ")", count: 500)
        #expect(CoreTelemetryService.sanitizeLocalPaths(nestedParens) == nestedParens)
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://api.telegram." + "org/bot123:%2FopaqueSecret123/sendMessage")
                == "https://api.telegram.org/bot123:[redacted]/sendMessage"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook%2FfakeToken")
                == "https://example.test/webhook%2F[redacted]"
        )
    }

    @Test("Handles outer-quoted nested webhooks, apostrophes, and unclosed quote fallback")
    func handlesOuterQuotedNestedWebhooksApostrophesAndUnclosedQuoteFallback() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "'https://example.test/webhook/fakeToken('a)first opaqueSecret123')'"
            ) == "'https://example.test/webhook/[redacted]'"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "\"https://example.test/webhook/fakeToken('a)first opaqueSecret123')\""
            ) == "\"https://example.test/webhook/[redacted]\""
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "https://example.test/wiki/Writer_(O'Reilly)?private=opaqueSecret123"
            ) == "https://example.test/wiki/Writer_(O'Reilly)?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/wiki/(Writers')?private=opaqueSecret123")
                == "https://example.test/wiki/(Writers')?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/wiki/('unclosed)?private=opaqueSecret123")
                == "https://example.test/wiki/('unclosed)?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("'see https://example.com/api{tag:\"value\"}?outer=value'")
                == "'see https://example.com/api{tag:\"value\"}?[redacted]'"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "https://example.com/api{url:\"see https://other.com/webhook/fakeToken('a)first opaqueSecret123')\"}?outer=value"
            ) == "https://example.com/api{url:\"see https://other.com/webhook/[redacted]\"}?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "https://example.com/api{url:\"see https://other.com/webhook/fakeToken('a)first opaqueSecret123')\"}"
            ) == "https://example.com/api{url:\"see https://other.com/webhook/[redacted]\"}"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{'a':'https://example.test/webhook/fakeToken('}")
                == "{'a':'https://example.test/webhook/[redacted]'}"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "{\"a\":\"https://example.test/webhook/fakeToken(\",\"b\":\"public-text\"}"
            ) == "{\"a\":\"https://example.test/webhook/[redacted]\",\"b\":\"public-text\"}"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://a.test/webhook/tok(\",\"https://other.com/webhook/tok2('x)secret')\"]"
            ) == "[\"https://a.test/webhook/[redacted]\",\"https://other.com/webhook/[redacted]\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "'https://example.test/webhook/fakeToken('a)first opaqueSecret123',https://other.test/x)'"
            ) == "'https://example.test/webhook/[redacted]'"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "'https://example.test/webhook/fakeToken('a)first opaqueSecret123', more)'"
            ) == "'https://example.test/webhook/[redacted]', more)'"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.test/webhook/fakeToken(\",\")public-text\"]"
            ) == "[\"https://example.test/webhook/[redacted]\",\")public-text\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "'https://example.test/webhook/fakeToken(' opaqueSecret123')'"
            ) == "'https://example.test/webhook/[redacted]'"
        )
    }

    @Test("Handles container-aware outer quote closers and punctuation-leading quoted secrets")
    func handlesContainerAwareOuterQuoteClosersAndPunctuationLeadingQuotedSecrets() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "'https://example.test/webhook/fakeToken(' )opaqueSecret123')'"
            ) == "'https://example.test/webhook/[redacted]'"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "'https://example.test/webhook/fakeToken(') opaqueSecret123')'"
            ) == "'https://example.test/webhook/[redacted]'"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "'https://example.test/webhook/fakeToken(')first opaqueSecret123')'"
            ) == "'https://example.test/webhook/[redacted]'"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "'https://example.test/webhook/fakeToken('} opaqueSecret123')'"
            ) == "'https://example.test/webhook/[redacted]'"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.test/webhook/fakeToken(\",123,\")public-text\"]"
            ) == "[\"https://example.test/webhook/[redacted]\",123,\")public-text\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[{\"a\":\"https://example.test/webhook/fakeToken(\"},\")public\"]"
            ) == "[{\"a\":\"https://example.test/webhook/[redacted]\"},\")public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "['https://example.test/webhook/fakeToken(',123, opaqueSecret123')']"
            ) == "['https://example.test/webhook/[redacted]']"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "['https://example.test/webhook/fakeToken(',{ opaqueSecret123')']"
            ) == "['https://example.test/webhook/[redacted]']"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\n  \"https://example.test/webhook/fakeToken(\",123,\")public-text\"]"
            ) == "[\n  \"https://example.test/webhook/[redacted]\",123,\")public-text\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "'https://example.test/webhook/fakeToken('unclosed opaqueSecret123"
            ) == "'https://example.test/webhook/[redacted]"
        )
    }

    @Test("Enforces RFC 8259 quote precedence and JSON escapes in prefixed and array URLs")
    func enforcesRFC8259QuotePrecedenceAndJSONEscapes() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.test/webhook/fakeToken('open\",123,\")public\"]"
            ) == "[\"https://example.test/webhook/[redacted]\",123,\")public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.test/webhook/fakeToken('a\",\")public-text\"]"
            ) == "[\"https://example.test/webhook/[redacted]\",\")public-text\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"see https://example.test/webhook/fakeToken('open\",123,\")public\"]"
            ) == "[\"see https://example.test/webhook/[redacted]\",123,\")public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"see https://example.test/webhook/fakeToken('a)first opaqueSecret123')\"]"
            ) == "[\"see https://example.test/webhook/[redacted]\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.test/webhook/fakeToken(\\\"opaqueSecret123)\"]"
            ) == "[\"https://example.test/webhook/[redacted]\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.test/webhook/fakeToken(\\\"opaqueSecret123\\\")\"]"
            ) == "[\"https://example.test/webhook/[redacted]\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.test/webhook/fakeToken(\\\"first opaqueSecret123\\\")\",\"public\"]"
            ) == "[\"https://example.test/webhook/[redacted]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.test/webhook/fakeToken\\\"opaqueSecret123\"]"
            ) == "[\"https://example.test/webhook/[redacted]\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.com/api{1:\\\"see https://other.com/x?token=opaqueSecret123\\\"}?outer=value\"]"
            ) == "[\"https://example.com/api{1:\\\"see https://other.com/x?[redacted]}?[redacted]\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.com/api?token=opaqueSecret123\\\"moreSecret\"]"
            ) == "[\"https://example.com/api?[redacted]\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.com/api?token=first\\\",opaqueSecret123\",\"public\"]"
            ) == "[\"https://example.com/api?[redacted]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.com/api{1:\\\"see https://other.com/x?token=opaqueSecret123\\\"}\"]"
            ) == "[\"https://example.com/api{1:\\\"see https://other.com/x?[redacted]}\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api?token=first\\\"opaqueSecret123")
                == "https://example.com/api?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"see \\\"example https://example.com/api?token=first\\\",opaqueSecret123\"]"
            ) == "[\"see \\\"example https://example.com/api?[redacted]\"]"
        )
        let repeatedRejected = String(repeating: "https:// ", count: 2000)
        #expect(CoreTelemetryService.sanitizeLocalPaths(repeatedRejected) == "http[redacted-path] ")
    }

    @Test("Allows angle brackets in quoted URL queries and preserves double quotes on redacted filenames")
    func quotedQueryAngleBracketsAndJsonFilenameQuotes() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.com/api?token=first\\\">opaqueSecret123\"]"
            ) == "[\"https://example.com/api?[redacted]\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.com/api?token=first<opaqueSecret123\",\"public\"]"
            ) == "[\"https://example.com/api?[redacted]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.com/api(x)?token=first<opaqueSecret123\",\"public\"]"
            ) == "[\"https://example.com/api(x)?[redacted]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"see <https://example.com/api?token=secret> public\"]"
            ) == "[\"see <https://example.com/api?[redacted]> public\"]"
        )
        #expect(CoreTelemetryService.sanitizeLocalPaths("[\"Acquisition.mov\"]") == "[\"[redacted-path]\"]")
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[\"report.pdf\",\"public\"]")
                == "[\"[redacted-path]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.com/api?token=opaqueSecret123\",\"Quarterly Report.pdf\"]"
            ) == "[\"https://example.com/api?[redacted]\",\"[redacted-path]\"]"
        )
    }

    @Test("Handles angle-wrapped URL queries, escaped Bearer quotes, and quoted JSON paths")
    func angleWrappedQueriesBearerEscapesAndQuotedJsonPaths() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"see <https://example.com/api?token=first<opaqueSecret123> public\"]"
            ) == "[\"see <https://example.com/api?[redacted]> public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "<https://example.com/api?token=first<opaqueSecret123> public"
            ) == "<https://example.com/api?[redacted]> public"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[\"Bearer abc\\\"opaqueSecret123\"]")
                == "[\"Bearer [redacted]\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[\"Bearer abc\\\"opaqueSecret123\",\"public\"]")
                == "[\"Bearer [redacted]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[\"Bearer abc\\\\\",\"public\"]")
                == "[\"Bearer [redacted]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[\"C://Secret/Acquisition.mov\",\"public\"]")
                == "[\"[redacted-path]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[\"Failed reading C://Secret/Acquisition.mov\",\"public\"]")
                == "[\"Failed reading [redacted-path]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[\"/Users/alice/Secret.mov\",\"public\"]")
                == "[\"[redacted-path]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[\"relative/Secret.mov\",\"public\"]")
                == "[\"[redacted-path]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "[\"https://example.com/api?token=opaqueSecret123\",\"C://Secret/Acquisition.mov\",\"public\"]"
            ) == "[\"https://example.com/api?[redacted]\",\"[redacted-path]\",\"public\"]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[\"hello \\\"world\\\"\",\"public\"]")
                == "[\"hello \\\"world\\\"\",\"public\"]"
        )
        #expect(CoreTelemetryService.sanitizeLocalPaths("[\"/\",\"public\"]") == "[\"/\",\"public\"]")
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[\"\\/private/secret\",\"public\"]")
                == "[\"[redacted-path]\",\"public\"]"
        )
        #expect(CoreTelemetryService.sanitizeLocalPaths("[\"\\/\",\"public\"]") == "[\"\\/\",\"public\"]")
        #expect(CoreTelemetryService.sanitizeLocalPaths("[\"relative/\",\"public\"]") == "[\"relative/\",\"public\"]")
        let manySlashes = "[\"\(String(repeating: "/", count: 10_000))\",\"public\"]"
        #expect(CoreTelemetryService.sanitizeLocalPaths(manySlashes) == manySlashes)
    }

    @Test("Handles JSON escape sequences in quoted paths and preserves unquoted path fail-closed behavior")
    func quotedJsonEscapePathsAndFallbackBoundaries() {
        let cases: [(String, String)] = [
            ("[\"relative\\/\",\"public\"]", "[\"relative\\/\",\"public\"]"),
            ("[\"relative\\u002F\",\"public\"]", "[\"relative\\u002F\",\"public\"]"),
            ("[\"\\u002Fprivate\",\"public\"]", "[\"[redacted-path]\",\"public\"]"),
            ("[\"\\u002fAcquisition\",\"public\"]", "[\"[redacted-path]\",\"public\"]"),
            ("[\"C\\u003A\\u002FSecret\",\"public\"]", "[\"[redacted-path]\",\"public\"]"),
            ("[\"\\u007E\\u002FSecret\",\"public\"]", "[\"[redacted-path]\",\"public\"]"),
            ("[\"\\u005C\\u005CServer\\u005CShare\",\"public\"]", "[\"[redacted-path]\",\"public\"]"),
            ("[\"hello\\nworld\",\"public\"]", "[\"hello\\nworld\",\"public\"]"),
            ("[\"path=secret\",\"public\"]", "[\"path=[redacted-path]\",\"public\"]"),
            ("Failed reading /Users/alice/My \"Secret\" Folder/file.mov", "Failed reading [redacted-path]"),
        ]
        for (input, expected) in cases {
            #expect(CoreTelemetryService.sanitizeLocalPaths(input) == expected)
        }
    }
}

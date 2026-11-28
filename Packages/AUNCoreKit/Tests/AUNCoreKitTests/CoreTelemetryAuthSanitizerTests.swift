import Foundation
import Testing

@testable import AUNCoreKit

@Suite("CoreTelemetryAuthSanitizer")
struct CoreTelemetryAuthSanitizerTests {
    @Test("Scrubs quote-prefixed and truncated JSON auth objects, non-JSON commas, and URL path tokens")
    func scrubsQuotePrefixedTruncatedObjectsAndURLTokens() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "note \" {\"Authorization\":{\"token\":\n\"opaqueSecret123\"\n},\"status\":\"safe\"}"
            ) == "note \" {\"Authorization\":\"[redacted]\",\"status\":\"safe\"}"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"Authorization\":{\n\"token\":\"opaqueSecret123\"\n")
                == "{\"Authorization\":\"[redacted]\""
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("prefix, \"Authorization\": \"firstValue\" }opaqueSecret123")
                == "prefix, \"Authorization\": \"[redacted]\" [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"status\":401,\"Authorization\":\"opaqueSecret123\"}")
                == "{\"status\":401,\"Authorization\":\"[redacted]\"}"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"Authorization\":\"firstValue\", \"opaqueSecret123\"}")
                == "{\"Authorization\":\"[redacted]\"[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("note \"hi\", \"Authorization\": \"firstValue\" } opaqueSecret123")
                == "note \"hi\", \"Authorization\": \"[redacted]\" [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("note: \"hi\", \"Authorization\": \"firstValue\" } opaqueSecret123")
                == "note: \"hi\", \"Authorization\": \"[redacted]\" [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "request, \"note\": \"hi\", \"Authorization\": \"firstValue\" } opaqueSecret123"
            ) == "request, \"note\": \"hi\", \"Authorization\": \"[redacted]\" [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"bad\tkey\":\"hi\",\"Authorization\":\"firstValue\" } opaqueSecret123")
                == "{\"bad\tkey\":\"hi\",\"Authorization\":\"[redacted]\" [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"a\":1,\"b\":\"hi\",\"Authorization\":\"opaqueSecret123\"}")
                == "{\"a\":1,\"b\":\"hi\",\"Authorization\":\"[redacted]\"}"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"a\":{\"b\":1},\"Authorization\":\"opaqueSecret123\"}")
                == "{\"a\":{\"b\":1},\"Authorization\":\"[redacted]\"}"
        )
        let repeatedMalformedBack = "\"\n" + String(repeating: "}, \"Authorization\": ", count: 2_000)
        #expect(!CoreTelemetryService.sanitizeLocalPaths(repeatedMalformedBack).isEmpty)
        let nestedJsonAuth =
            String(repeating: "{\"a\":", count: 2_000) + "{}"
            + String(repeating: ",\"Authorization\":\"secret\"}", count: 2_000)
        let scrubbedNested = CoreTelemetryService.sanitizeLocalPaths(nestedJsonAuth)
        #expect(!scrubbedNested.contains("secret"))
        #expect(scrubbedNested.hasSuffix(",\"Authorization\":\"[redacted]\"}"))
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://discord." + "com/api/webhooks/123456789/fakeWebhookToken")
                == "https://discord.com/api/webhooks/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://hooks.slack." + "com/services/T0000/B0000/fakeWebhookToken")
                == "https://hooks.slack.com/services/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://hooks.slack." + "com:443/services/T0000/B0000/fakeWebhookToken")
                == "https://hooks.slack.com:443/services/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://api.telegram." + "org/bot123456:fakeBotToken/getMe")
                == "https://api.telegram.org/bot123456:[redacted]/getMe"
        )
    }

    @Test("Rejects invalid JSON escapes/mismatched containers and scrubs comma/percent-encoded webhook URLs")
    func rejectsMalformedJsonAndScrubsEncodedWebhookURLs() {
        let badEscapeScrubbed = CoreTelemetryService.sanitizeLocalPaths(
            "{\"bad\\qkey\":\"hi\",\"Authorization\":\"firstValue\" } opaqueSecret123"
        )
        #expect(!badEscapeScrubbed.contains("firstValue"))
        #expect(!badEscapeScrubbed.contains("opaqueSecret123"))
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"\\q\":\"hi\",\"Authorization\":\"firstValue\" } opaqueSecret123")
                == "{\"\\q\":\"hi\",\"Authorization\":\"[redacted]\" [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"a\":[{],\"Authorization\":\"firstValue\" } opaqueSecret123")
                == "{\"a\":[{],\"Authorization\":\"[redacted]\" [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"Authorization\":\"bad\\qval\" } opaqueSecret123")
                == "{\"Authorization\":\"[redacted]\" [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"\\Authorization\":\"firstValue\" } opaqueSecret123")
                == "{\"Authorization\":\"[redacted]\" [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"Authorization\":\"firstValue\" } opaqueSecret123")
                == "{\"Authorization\":\"[redacted]\" [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"Authorization\":\"firstValue\",\"a\":[{]} opaqueSecret123")
                == "{\"Authorization\":\"[redacted]\"[redacted]"
        )
    }

    @Test("Climbs nested JSON containers, redacts multiline truncated arrays, and scrubs grouped webhook tokens")
    func climbsContainersRedactsMultilineArraysAndGroupedWebhooks() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[{\"Authorization\":\"opaqueSecret123\"},{\"status\":\"safe\"}]")
                == "[{\"Authorization\":\"[redacted]\"},{\"status\":\"safe\"}]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[{\"Authorization\":\"opaqueSecret123\" }\n]")
                == "[{\"Authorization\":\"[redacted]\" }\n]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("[{\"Authorization\":\"firstValue\" }\n] opaqueSecret123")
                == "[{\"Authorization\":\"[redacted]\" [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"Authorization\":\"firstValue\"\n} opaqueSecret123")
                == "{\"Authorization\":\"[redacted]\"\n[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"Authorization\":[\"firstValue\",\n\"opaqueSecret123\"")
                == "{\"Authorization\":[\"[redacted]\",\n\"[redacted]\""
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"Authorization\":[\n\"opaqueSecret123\"\n")
                == "{\"Authorization\":[\n\"[redacted]\"\n"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"\\q\":\"hi\",\"Authorization\":[\"firstValue\",\n\"opaqueSecret123\"")
                == "{\"\\q\":\"hi\",\"Authorization\":[\"[redacted]\",\n\"[redacted]\""
        )
        let badEscapeArray = CoreTelemetryService.sanitizeLocalPaths(
            "{\"bad\\qkey\":\"hi\",\"Authorization\":[\"firstValue\",\n\"opaqueSecret123\""
        )
        #expect(!badEscapeArray.contains("firstValue"))
        #expect(!badEscapeArray.contains("opaqueSecret123"))
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken,remainingSecret123")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/,remainingSecret123")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken,(remainingSecret123)")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken,(tag:opaqueSecret123)")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken(tag:opaqueSecret123)")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken(tag:opaqueSecret123,)")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken,(tag:opaqueSecret123")
                == "https://example.test/webhook/[redacted]"
        )
    }

    @Test("Scrubs comma-query, semicolon-comma, and leading-colon grouped webhook URLs")
    func scrubsWebhookCommaQuerySemicolonAndColonGroups() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken,?token=opaqueSecret123")
                == "https://example.test/webhook/[redacted]?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api,?token=opaqueSecret123")
                == "https://example.com/api,?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken;,(tag:opaqueSecret123)")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken(:opaqueSecret123)")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken,;opaqueSecret123")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken,'opaqueSecret123")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken,)opaqueSecret123")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken)opaqueSecret123")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("(https://example.test/webhook/fakeToken)")
                == "(https://example.test/webhook/[redacted])"
        )
        let repeatedBot = "https://api.telegram." + "org/bot1:a" + String(repeating: "%2Fbot2:b", count: 500)
        #expect(CoreTelemetryService.sanitizeLocalPaths(repeatedBot) == "https://api.telegram.org/bot1:[redacted]")
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/%77ebhook/fakeToken")
                == "https://example.test/%77ebhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken, next")
                == "https://example.test/webhook/[redacted], next"
        )
    }

    @Test("Scrubs general URL continuations, quoted webhooks, and encoded-slash Telegram URLs")
    func scrubsGeneralURLContinuationsAndEncodedSlashTelegramURLs() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("'https://example.test/webhook/fakeToken',)opaqueSecret123")
                == "'https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("'https://example.test/webhook/fakeToken', next")
                == "'https://example.test/webhook/[redacted]', next"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken,/opaqueSecret123")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api,public?token=opaqueSecret123")
                == "https://example.com/api,public?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api,public#token=opaqueSecret123")
                == "https://example.com/api,public#[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api,/public?token=opaqueSecret123")
                == "https://example.com/api,[redacted-path]?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api,private/Secret.mov?token=opaqueSecret123")
                == "https://example.com/api,[redacted-path]?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com(/Users/alice/Secret.mov)?token=opaqueSecret123")
                == "https://example.com([redacted-path])?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api,alice@example.com?token=opaqueSecret123")
                == "https://example.com/api,[redacted-email]?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api)public?token=opaqueSecret123")
                == "https://example.com/api)public?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api(tag:val)?token=opaqueSecret123")
                == "https://example.com/api(tag:val)?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api,public/webhook/opaqueSecret123")
                == "https://example.com/api,[redacted-path]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com(/Users/alice/Secret.mov)/webhook/opaqueSecret123")
                == "https://example.com([redacted-path])[redacted-path]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "https://api.telegram." + "org/bot123:opaqueSecret123,/Users/alice/Secret.mov")
                == "https://api.telegram.org/bot123:[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api,https://other.com/x?token=opaqueSecret123")
                == "https://example.com/api,https://other.com/x?[redacted]"
        )
    }

    @Test("Handles RFC 3986 schemes and closing delimiters in URL continuations")
    func handlesRFC3986SchemesAndClosingDelimitersInURLContinuations() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api,ssh://other.com/x?token=opaqueSecret123")
                == "https://example.com/api,ssh://other.com/x?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api)private/Secret?token=opaqueSecret123")
                == "https://example.com/api)[redacted-path]?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api]private/Secret?token=opaqueSecret123")
                == "https://example.com/api][redacted-path]?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api}?token=opaqueSecret123")
                == "https://example.com/api}?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/users/{id}?token=opaqueSecret123")
                == "https://example.com/users/{id}?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api}private/Secret?token=opaqueSecret123")
                == "https://example.com/api}[redacted-path]?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{https://example.test/webhook/fakeToken}")
                == "{https://example.test/webhook/[redacted]}"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken{tag:opaqueSecret123}")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/users/{id}/profile?token=opaqueSecret123")
                == "https://example.com/users/{id}/profile?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/users/{private/Secret.mov}?token=opaqueSecret123")
                == "https://example.com/users/{[redacted-path]?[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.test/webhook/fakeToken{tag:\"opaqueSecret123\"}")
                == "https://example.test/webhook/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api{tag:\"value\"}?token=opaqueSecret123")
                == "https://example.com/api{tag:\"value\"}?[redacted]"
        )
    }
}

extension CoreTelemetryAuthSanitizerTests {
    @Test("Scrubs quoted Bearer/Basic credentials, slash-local emails, and linear IP literals")
    func scrubsQuotedBearerBasicSlashEmailsAndLinearIPLiterals() {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("received Bearer \"opaqueSecret123\" during handshake")
                == "received Bearer \"[redacted]\" during handshake"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("received Bearer 'opaqueSecret123' during handshake")
                == "received Bearer '[redacted]' during handshake"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"m\":\"Basic \\\"dXNlcjpwYXNz\\\"\"}")
                == "{\"m\":\"Basic \\\"[redacted]\\\"\"}"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("received Basic \"dXNlcjpwYXNz\" during handshake")
                == "received Basic \"[redacted]\" during handshake"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("received Basic 'dXNlcjpwYXNz' during handshake")
                == "received Basic '[redacted]' during handshake"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("Bearer \"hello world\"") == "Bearer \"hello world\""
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("Bearer Bearer \"opaqueSecret123\"")
                == "Bearer Bearer \"[redacted]\""
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("Bearer Bearer opaqueSecret123")
                == "Bearer Bearer [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("Bearer Basic \"dXNlcjpwYXNz\"")
                == "Bearer Basic \"[redacted]\""
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("Basic Basic \"dXNlcjpwYXNz\"")
                == "Basic Basic \"[redacted]\""
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("Basic Basic dXNlcjpwYXNz")
                == "Basic Basic [redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("{\"m\":\"Basic Basic \\\"dXNlcjpwYXNz\\\"\"}")
                == "{\"m\":\"Basic Basic \\\"[redacted]\\\"\"}"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.org/users/alice/@example.com")
                == "https://[redacted-email]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.org/users/alice/%40example.com")
                == "https://[redacted-email]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://registry.npmjs.org/@angular/core")
                == "https://registry.npmjs.org/@angular/core"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://registry.npmjs.org/%40angular/core")
                == "https://registry.npmjs.org/%40angular/core"
        )
        let repeatedOpen = String(repeating: "x@[", count: 10_000)
        #expect(CoreTelemetryService.sanitizeLocalPaths(repeatedOpen) == repeatedOpen)
    }
}

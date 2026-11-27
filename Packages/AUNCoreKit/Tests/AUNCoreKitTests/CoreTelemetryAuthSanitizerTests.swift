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
}

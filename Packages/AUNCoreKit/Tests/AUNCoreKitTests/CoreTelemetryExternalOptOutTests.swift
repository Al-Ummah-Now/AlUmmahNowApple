import AUNCoreBridge
import Foundation
import Testing

@testable import AUNCoreKit

@Suite("CoreTelemetryExternalOptOut")
struct CoreTelemetryExternalOptOutTests {
    @Test("Direct UserDefaults opt-out purges persisted retry buffer after close() with no active flush")
    func directDefaultsOptOutPurgesClosedRetryBuffer() throws {
        let suiteName = "net.alummahnow.test.closed-revoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: "AUNTelemetryEnabled")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aun-tel-closed-revoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bufferPath = dir.appendingPathComponent("telemetry-buffer.json").path

        nonisolated(unsafe) let defaultsRef = defaults
        let service = try CoreTelemetryService(
            platform: "macos", appVersion: "1.0.0", osVersion: "15.0", deviceClass: "desktop",
            locale: "en", videosAPIBaseURL: nil, userAgent: "AUNTest/1.0",
            bufferPath: bufferPath, initialEnabled: true,
            isExternallyEnabled: { defaultsRef.bool(forKey: "AUNTelemetryEnabled") },
            observedDefaults: defaults, observedDefaultsKey: "AUNTelemetryEnabled")
        service.reportCrash(kind: "NSException", message: "closed crash", stack: nil)
        service.persist()
        #expect(FileManager.default.fileExists(atPath: bufferPath))

        service.close()
        #expect(FileManager.default.fileExists(atPath: bufferPath))

        let otherInstance = UserDefaults(suiteName: suiteName)!
        otherInstance.set(false, forKey: "AUNTelemetryEnabled")
        #expect(service.nativeConsentForTesting == .denied)
        #expect(!FileManager.default.fileExists(atPath: bufferPath))
    }

    @Test("UnavailableNativeTelemetryService purges leftover buffer and fails closed")
    func unavailableFallbackPurgesLeftoverBuffer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aun-tel-unavail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bufferPath = dir.appendingPathComponent("telemetry-buffer.json").path
        try Data("{\"events\":[]}".utf8).write(to: URL(fileURLWithPath: bufferPath))

        let fallback = UnavailableNativeTelemetryService(bufferPath: bufferPath)
        #expect(fallback.consent == .off)
        #expect(!fallback.lastPurgeFailed)
        #expect(!FileManager.default.fileExists(atPath: bufferPath))
        #expect(!fallback.setConsent(.full))
        #expect(fallback.setConsent(.off))
    }

    @Test("Property keys, identifiers, and share-link tokens scrub JWTs, IPs, Unicode phones, and short tokens")
    func propertyKeysIdentifiersAndShareLinksScrubbed() throws {
        let props = CoreTelemetryService.serializeProperties([
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig_part-1": "failed",
            "192.0.2.10": "ok",
            "2001:db8::beef:cafe": "failed",
            "fe80::1": "ok",
            "+٩٧١٥٠١٢٣٤٥٦": "ok",
            "detail": "Peer 192.0.2.10 called +٩٧١٥٠١٢٣٤٥٦ from fe80::1",
            "share": "https://share.example.com/s/V8r2Qp6Lm4",
            "dropbox": "https://www.dropbox.com/scl/fi/a1b2c3d4e5f6g7h8i9j0/PrivateAcquisition.pdf",
        ])
        #expect(props != nil)
        #expect(!(props?.contains("eyJhbGciOiJIUzI1NiJ9") ?? true))
        #expect(!(props?.contains("192.0.2.10") ?? true))
        #expect(!(props?.contains("beef:cafe") ?? true))
        #expect(!(props?.contains("fe80") ?? true))
        #expect(!(props?.contains("٩٧١٥٠١٢٣٤٥٦") ?? true))
        #expect(!(props?.contains("V8r2Qp6Lm4") ?? true))
        #expect(!(props?.contains("PrivateAcquisition") ?? true))
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://share.example.com/s/V8r2Qp6Lm4")
                == "https://share.example.com/s/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths(
                "https://www.dropbox.com/scl/fi/a1b2c3d4e5f6g7h8i9j0/PrivateAcquisition.pdf"
            ) == "https://www.dropbox.com/scl/[redacted]"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("http://u:p@localhost/x")
                == "http://[redacted]@localhost/x"
        )
    }

    @Test("Diagnostic text, keys, and URLs scrub JOSE tokens, IPs, Unicode phones, credentials, and share links")
    func diagnosticTextKeysAndURLsScrubbed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aun-tel-id-scrub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bufferPath = dir.appendingPathComponent("telemetry-buffer.json").path
        let service = try CoreTelemetryService(
            platform: "macos", appVersion: "1.0.0", osVersion: "15.0", deviceClass: "desktop",
            locale: "en", videosAPIBaseURL: nil, userAgent: "AUNTest/1.0",
            bufferPath: bufferPath, initialEnabled: true)
        service.track("4155550123", properties: [:])
        service.track("phone_2025550123", properties: [:])
        service.track("peer 2001:db8::beef:cafe", properties: ["2001:db8::beef:cafe": "failed"])
        service.track(
            "signin_attempt",
            properties: [
                "verificationCode": "482193",
                "challenge.verificationCode": "654321",
                "user_id": "alice123",
                "p\\u0061ssword": "violet-sparrow",
                "token violet7": "ok",
                "token=cobalt-orchard": "ok",
                "http://u:p@localhost/x": "ok",
                "eyJunction.load.failed": "ok",
            ]
        )
        service.addBreadcrumb(
            category: "http://u:p@localhost/x",
            message: "Remote peer 10.0.0.123. source:2001:db8::1 peer 2001:db8:0:0:0:0:192.0.2.81 "
                + "Call ٠٥٠\u{2011}١٢٣\u{2011}٤٥٦٧ +𝟏𝟐𝟏𝟐\u{2212}𝟓𝟓𝟓\u{2212}𝟎𝟏𝟐𝟑 phone 12 34 56 78 "
                + "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhbGljZSJ9. IHsiYWxnIjoiSFMyNTYifQ.eyJzdWIiOiIxIn0.sig123 "
                + #"{"challenge.verificationCode":"739104"} {"pass":"multi word phrase"} {"userId":["alice42", "bob73"]} "#
                + #"fullName="Alice Wonderland" username=Jane Doe C:ProjectCodename C:秘密 pwd=shortsecret "#
                + "https://1drv.ms/u/s!Aq82F1ZLPx0K "
                + "https://example.org/assets/%41bCdEfGhIjKlMnOpQrStUvWxYz0123456789 "
                + "https://example.test/lookup/%2B%31%32%30%32%35%35%35%30%31%32%33 "
                + "https://example.test/contact/%2B%31%20%32%30%32%20%35%35%35%20%30%31%32%33 "
                + "https://example.test/lookup/202%C2%A0555%C2%A00123 "
                + "https://example.test/lookup/alice%2540example.test "
                + "https://example.test/%2572eset-password/AbCdEf123456 "
                + "https%25253A%25252F%25252Fexample.test%25252Flogin%25253Ftoken%25253Ds3cr3t "
                + "ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ "
                + "https://uploads.example.test/upload/853876e8-cc19-465d-bafa-7459aba00936 "
                + "alummahnow://watch/v1 "
                + "https://example.com/download/eyJhbGciOiJkaXIifQ%2E%2Eiv1234%2Ecipher7777%2Etag8888",
            level: .info
        )
        service.reportCrash(
            kind: "4155550123",
            message: #"clientSecret="cobalt orchard" status="password=first;second" "#
                + #"eyJhbGciOiJkaXIifQ..iv1234.cipher5678.tag9012 "#
                + #"{"home\u0041ddress":"12 Cedar Rd"} displayName=Alice Smith "#
                + "password=\u{201C}orchid velvet\u{201D} "
                + "https://example.test/password%3Dshortcredential "
                + "https%3A%2F%2Fexample.test%2F%3Fcode%3Dorchid-meadow "
                + "https://drive.google.com/file/u/0/d/AbCdEfGhIjKlMnOpQrStUvWxYzABCDE/view "
                + "https://example.com/a;jsessionid=abc123",
            stack: nil
        )
        service.persist()
        let raw = try String(contentsOfFile: bufferPath, encoding: .utf8)
        let forbidden = [
            "4155550123", "2025550123", "10.0.0.123", "2001:db8", "192.0.2.81", "١٢٣", "𝟏𝟐𝟏𝟐", "12 34 56 78",
            "beef:cafe", "482193", "654321", "739104", "alice123", "alice42", "bob73", "violet-sparrow", "秘密", "violet7",
            "first;second", "second",
            "Jane", "Doe", "ProjectCodename", "multi word phrase", "word phrase",
            "Alice", "Wonderland", "Smith", "orchid-meadow", "velvet", "shortsecret", "shortcredential",
            "12 Cedar Rd", "u:p@localhost",
            "u:[redacted-email]", "cobalt-orchard", "orchard", "eyJzdWIiOiJhbGljZSJ9",
            "sig123", "cipher5678", "cipher7777", "Aq82F1ZLPx0K",
            "bCdEfGhIjKlMnOpQrStUvWxYz0123456789", "853876e8-cc19-465d-bafa-7459aba00936", "watch/v1",
            "%2B%31%32%30%32", "%2B%31%20%32%30%32", "202%C2%A0555", "alice%2540example.test", "AbCdEf123456",
            "s3cr3t", "ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ",
            "AbCdEfGhIjKlMnOpQrStUvWxYzABCDE", "abc123",
        ]
        for token in forbidden {
            #expect(!raw.contains(token), "Expected redacted token: \(token)")
        }
        #expect(raw.contains("eyJunction.load.failed"))
    }

    @Test("Locale tags sanitize paths and previous-session fatal signal markers report on relaunch")
    func localeTagSanitizationAndPreviousSessionSignalCrash() throws {
        #expect(CoreTelemetryService.sanitizeLocaleTag("/Users/Ada/Private.mov") == "en")
        #expect(CoreTelemetryService.sanitizeLocaleTag("ar-SA") == "ar-SA")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aun-tel-sigcrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bufferPath = dir.appendingPathComponent("telemetry-buffer.json").path
        let markerPath = bufferPath + ".crash-signal"
        try Data("SIGTRAP\n".utf8).write(to: URL(fileURLWithPath: markerPath))

        let service = try CoreTelemetryService(
            platform: "macos", appVersion: "1.0.0", osVersion: "15.0", deviceClass: "desktop",
            locale: "/Users/Ada/Private.mov", videosAPIBaseURL: nil, userAgent: "AUNTest/1.0",
            bufferPath: bufferPath, initialEnabled: true)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
        let persisted = try String(contentsOfFile: bufferPath, encoding: .utf8)
        #expect(persisted.contains("FatalSignal"))
        #expect(persisted.contains("SIGTRAP"))
        #expect(!persisted.contains("Private.mov"))
        service.close()
        #expect(!CrashTelemetryHook.isSignalTrapInstalled)
    }

    @Test("Signal hook stays uninstalled when disabled, purges markers in unavailable fallback, and redacts user routes")
    func signalHookDisabledFallbackMarkerPurgeAndUserRoutes() throws {
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("GET https://example.com/users/AliceSmith failed")
                == "GET https://example.com/users/[redacted] failed")
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/%75sers/BobJones")
                == "https://example.com/%75sers/[redacted]")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aun-tel-sigoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bufferPath = dir.appendingPathComponent("telemetry-buffer.json").path
        let markerPath = bufferPath + ".crash-signal"

        let disabled = try CoreTelemetryService(
            platform: "macos", appVersion: "1.0.0", osVersion: "15.0", deviceClass: "desktop",
            locale: "en", videosAPIBaseURL: nil, userAgent: "AUNTest/1.0",
            bufferPath: bufferPath, initialEnabled: false)
        CrashTelemetryHook.install(service: disabled)
        #expect(!CrashTelemetryHook.isSignalTrapInstalled)
        #expect(disabled.setConsent(.full))
        #expect(CrashTelemetryHook.isSignalTrapInstalled)
        #expect(disabled.setConsent(.off))
        #expect(!CrashTelemetryHook.isSignalTrapInstalled)
        disabled.close()

        try Data("SIGTRAP\n".utf8).write(to: URL(fileURLWithPath: markerPath))
        let fallback = UnavailableNativeTelemetryService(bufferPath: bufferPath)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
        #expect(!fallback.lastPurgeFailed)
        try Data("SIGABRT\n".utf8).write(to: URL(fileURLWithPath: markerPath))
        #expect(fallback.setConsent(.off))
        #expect(!FileManager.default.fileExists(atPath: markerPath))
        #expect(!fallback.lastPurgeFailed)
    }
}

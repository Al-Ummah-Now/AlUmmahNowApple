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
        service.track("peer 2001:db8::beef:cafe", properties: ["2001:db8::beef:cafe": "failed"])
        service.addBreadcrumb(category: "4155550123", message: "Peer 192.0.2.10 called +٩٧١٥٠١٢٣٤٥٦", level: .info)
        service.reportCrash(kind: "4155550123", message: "Peer 192.0.2.10 called +٩٧١٥٠١٢٣٤٥٦", stack: nil)
        service.persist()
        let raw = try String(contentsOfFile: bufferPath, encoding: .utf8)
        #expect(!raw.contains("4155550123"))
        #expect(!raw.contains("192.0.2.10"))
        #expect(!raw.contains("٩٧١٥٠١٢٣٤٥٦"))
        #expect(!raw.contains("beef:cafe"))
    }
}

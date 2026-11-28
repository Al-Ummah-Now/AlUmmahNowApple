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

        defaults.set(false, forKey: "AUNTelemetryEnabled")
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
}

import AUNCoreBridge
@testable import AUNCoreKit
import Foundation
import Testing

@Suite("CoreTelemetryService")
struct CoreTelemetryServiceTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aun-tel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Stays silent by default, records when opted in, and purges disk on revoke")
    func silentDefaultOptInAndPurge() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bufferPath = dir.appendingPathComponent("telemetry-buffer.json").path

        let service = try CoreTelemetryService(
            platform: "macos",
            appVersion: "1.2.3",
            osVersion: "macOS 15.0",
            deviceClass: "desktop",
            locale: "ar",
            videosAPIBaseURL: nil,
            userAgent: "AlUmmahNowStudioMac/1.2.3",
            bufferPath: bufferPath,
            initialEnabled: false
        )

        #expect(service.consent == .off)
        #expect(!service.lastPurgeFailed)

        service.track("screen_view", properties: ["screen": "home"])
        service.reportCrash(kind: "NSInvalidArgumentException", message: "boom", stack: "frame 0")
        #expect(service.pendingCount == 0)
        #expect(!FileManager.default.fileExists(atPath: bufferPath))

        #expect(service.setConsent(.full))
        #expect(service.consent == .full)
        service.addBreadcrumb(category: "nav", message: "opened settings", level: .info)
        service.track("screen_view", properties: ["screen": "settings"])
        service.reportCrash(kind: "NSInternalInconsistencyException", message: "crash", stack: "frame 1")
        #expect(service.pendingCount == 2)
        #expect(FileManager.default.fileExists(atPath: bufferPath))

        #expect(service.setConsent(.off))
        #expect(service.consent == .off)
        #expect(!service.lastPurgeFailed)
        #expect(service.pendingCount == 0)
        #expect(!FileManager.default.fileExists(atPath: bufferPath))
    }

    @Test("Flush drains buffered events when opted in")
    func flushDrainsBufferedEvents() async throws {
        let service = try CoreTelemetryService(
            platform: "ios",
            appVersion: "1.0.0",
            osVersion: "iOS 18.0",
            deviceClass: "phone",
            locale: "en",
            videosAPIBaseURL: nil,
            userAgent: "AlUmmahNowIOS/1.0.0",
            bufferPath: nil,
            initialEnabled: true
        )

        service.trackError("upload.timeout", properties: ["attempt": "2"])
        #expect(service.pendingCount == 1)

        await service.flush()
        #expect(service.pendingCount == 0)
    }

    @Test("Opt-out enforces wrapper denial and surfaces lastPurgeFailed when buffer cannot be removed")
    func purgeFailureEnforcesWrapperDenial() async throws {
        let dir = try makeTempDir()
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

        service.track("screen_view", properties: ["screen": "home"])
        service.persist()
        #expect(FileManager.default.fileExists(atPath: bufferPath))

        // Replace buffer file with a non-empty directory so remove fails.
        try FileManager.default.removeItem(atPath: bufferPath)
        try FileManager.default.createDirectory(atPath: bufferPath, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: bufferPath).appendingPathComponent("keep.txt"))

        #expect(!service.setConsent(.off))
        #expect(service.lastPurgeFailed)
        #expect(service.consent == .off)

        service.track("screen_view", properties: ["screen": "home"])
        service.reportCrash(kind: "Exception", message: "blocked")
        #expect(service.pendingCount == 0)
        await service.flush()
    }

    @Test("Failed enable transition fails closed in both wrapper and native consent")
    func failedEnableRollsBackBothStates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bufferPath = dir.appendingPathComponent("telemetry-buffer.json").path

        // Put a non-empty directory at bufferPath so native setConsent(.analytics) fails on load/persist.
        try FileManager.default.createDirectory(atPath: bufferPath, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: bufferPath).appendingPathComponent("keep.txt"))

        let service = try CoreTelemetryService(
            platform: "macos",
            appVersion: "1.0.0",
            osVersion: "macOS 15.0",
            deviceClass: "desktop",
            locale: "en",
            videosAPIBaseURL: nil,
            userAgent: "AlUmmahNowMac/1.0.0",
            bufferPath: bufferPath,
            initialEnabled: false
        )

        #expect(!service.setConsent(.full))
        #expect(service.consent == .off)
        #expect(service.nativeConsentForTesting == .denied)
        #expect(service.pendingCount == 0)
    }

    @Test("Concurrent revoke during flush never crashes and leaves buffer purged")
    func concurrentRevokeDuringFlush() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<6 {
            let bufferPath = dir.appendingPathComponent("buf-\(i).json").path
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
            for idx in 0..<8 {
                service.track("screen_view", properties: ["idx": "\(idx)"])
            }
            service.persist()

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await service.flush() }
                group.addTask { _ = service.setConsent(.off) }
            }

            #expect(service.consent == .off)
            #expect(service.pendingCount == 0)
            #expect(!FileManager.default.fileExists(atPath: bufferPath))
        }
    }

    @Test("Ordinary close during flush preserves retryable buffer")
    func closePreservesRetryableBuffer() async throws {
        let dir = try makeTempDir()
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
        service.flushOverrideForTesting = {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        service.track("screen_view", properties: ["screen": "home"])
        service.persist()
        #expect(FileManager.default.fileExists(atPath: bufferPath))

        let flushTask = Task { await service.flush() }
        try await Task.sleep(nanoseconds: 10_000_000)
        service.close()
        await flushTask.value

        #expect(FileManager.default.fileExists(atPath: bufferPath))
    }

    @Test("Crash reports and breadcrumbs redact local file paths")
    func reportCrashRedactsLocalPaths() throws {
        let dir = try makeTempDir()
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

        service.addBreadcrumb(
            category: "io",
            message: "Opened /workspace/E\u{0301}lodie/Very Secret Client Project Name.mov\nFailed '/data/user/0/O'Brien.mov'\nRead \"/Users/O'Brien/Final.mov\"",
            level: .info
        )
        service.reportCrash(
            kind: "IOException",
            message: #"Failed reading /Private (Client).mov\n/Private Client\n/private-key\n/workspace/alice/Project;Acquisition.mov\n"C:\Users\Alice Smith\Private Draft.mp4""#,
            stack: "at Player.open() in /workspace/Élodie/src/Player.swift:42\nat App.run()"
        )

        let json = try String(contentsOfFile: bufferPath, encoding: .utf8)
        #expect(!json.localizedCaseInsensitiveContains("alice"))
        #expect(!json.localizedCaseInsensitiveContains("smith"))
        #expect(!json.localizedCaseInsensitiveContains("lodie"))
        #expect(!json.localizedCaseInsensitiveContains("brien"))
        #expect(!json.localizedCaseInsensitiveContains("private"))
        #expect(!json.localizedCaseInsensitiveContains("acquisition"))
        #expect(!json.localizedCaseInsensitiveContains("client).mov"))
        #expect(!json.localizedCaseInsensitiveContains("name.mov"))
        #expect(!json.localizedCaseInsensitiveContains("draft.mp4"))
        #expect(!json.contains("workspace"))
        #expect(json.contains(":42"))
        #expect(json.contains("App.run()"))
        #expect(json.contains("[redacted-path]"))
    }

    @Test("Revoking after close() still revokes native consent and removes sibling temp files")
    func revokeAfterCloseRevokesNativeAndTempFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bufferPath = dir.appendingPathComponent("telemetry-buffer.json").path
        let tempPath = dir.appendingPathComponent(".telemetry-buffer.json.9999.tmp").path

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
        service.track("screen_view", properties: ["screen": "home"])
        service.persist()
        try Data("stale".utf8).write(to: URL(fileURLWithPath: tempPath))
        #expect(FileManager.default.fileExists(atPath: bufferPath))
        #expect(FileManager.default.fileExists(atPath: tempPath))

        service.close()
        #expect(service.setConsent(.off))
        #expect(service.nativeConsentForTesting == .denied)
        #expect(!FileManager.default.fileExists(atPath: bufferPath))
        #expect(!FileManager.default.fileExists(atPath: tempPath))
    }

    @Test("Resolve ingest URL requires HTTPS, strips path/query/fragment, and rejects credentials")
    func resolveIngestURLStrict() {
        #expect(
            CoreTelemetryService.resolveIngestURL("https://videos.api.alummahnow.net/")
                == "https://videos.api.alummahnow.net/api/v1/telemetry/batches")
        #expect(
            CoreTelemetryService.resolveIngestURL("https://videos.api.example/some/path?x=1#frag")
                == "https://videos.api.example/api/v1/telemetry/batches")
        #expect(
            CoreTelemetryService.resolveIngestURL("https://videos.api.example:8443/v2?token=abc#top")
                == "https://videos.api.example:8443/api/v1/telemetry/batches")
        #expect(
            CoreTelemetryService.resolveIngestURL("https://videos.api.example:443/v1")
                == "https://videos.api.example/api/v1/telemetry/batches")
        #expect(
            CoreTelemetryService.resolveIngestURL("https://videos.api.example?x=1")
                == "https://videos.api.example/api/v1/telemetry/batches")
        #expect(CoreTelemetryService.resolveIngestURL("https://user:pass@videos.api.example/path") == nil)
        #expect(CoreTelemetryService.resolveIngestURL("https://user@videos.api.example") == nil)
        #expect(CoreTelemetryService.resolveIngestURL("http://videos.api.alummahnow.net") == nil)
        #expect(CoreTelemetryService.resolveIngestURL("http://127.0.0.1:3086") == nil)
        #expect(CoreTelemetryService.resolveIngestURL("") == nil)
        #expect(CoreTelemetryService.resolveIngestURL(nil as String?) == nil)
    }
}

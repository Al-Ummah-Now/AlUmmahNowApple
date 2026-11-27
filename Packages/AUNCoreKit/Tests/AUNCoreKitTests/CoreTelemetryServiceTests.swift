import AUNCoreBridge
@testable import AUNCoreKit
import Foundation
import Testing

private final class TelemetryFlushSlotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex = 0
    private var slots: [Int: CheckedContinuation<Void, Never>] = [:]
    private var arrivedWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var arrivedSlots: Set<Int> = []

    func enter() async {
        let idx = lock.withLock { () -> Int in
            let i = nextIndex
            nextIndex += 1
            return i
        }
        await withCheckedContinuation { cont in
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                slots[idx] = cont
                arrivedSlots.insert(idx)
                return arrivedWaiters.removeValue(forKey: idx)
            }
            waiter?.resume()
        }
    }

    func waitForSlot(_ idx: Int) async {
        await withCheckedContinuation { cont in
            let ready = lock.withLock { () -> Bool in
                if arrivedSlots.contains(idx) { return true }
                arrivedWaiters[idx] = cont
                return false
            }
            if ready { cont.resume() }
        }
    }

    func releaseSlot(_ idx: Int) {
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            slots.removeValue(forKey: idx)
        }
        cont?.resume()
    }
}

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
        let gate = TelemetryFlushSlotGate()
        service.flushOverrideForTesting = {
            await gate.enter()
        }
        service.track("screen_view", properties: ["screen": "home"])
        service.persist()
        #expect(FileManager.default.fileExists(atPath: bufferPath))

        let flushTask = Task { await service.flush() }
        await gate.waitForSlot(0)
        service.close()
        gate.releaseSlot(0)
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
            message: """
            Failed reading /Private (Client).mov
            /Private Client
            /private-key
            /Users/alice/Secret<Project>.mov
            /Users/alice/Draft:77 in open() Acquisition.mov
            failed at path=/Users/alice/Secret"Acquisition.mov
            Failed to open "/ Secret/Acquisition.mov"
            Failed to open "/ SecretFile"
            / SecretFile.mov
            / SecretFile
            / SecretFile.abcdefghijkl
            // SecretFile
            42:/ Secret/Acquisition.mov:77
            error 42://SecretHost/Acquisition.mov
            open(path\\\\unc\\Secret\\Acquisition.mov)
            open(pathC:\\Secret\\Acquisition.mov)
            open(C://Secret/Acquisition.mov)
            C://Users\\Alice\\Secret.mov
            Could not find file 'Secret.mov'
            Could not find file 'private/Secret.mov'
            Could not find file './Secret.mov'
            Could not find file 'O'Brien.mov'
            Could not find file 'SecretBareName'
            Could not find file Secret.xyz
            open Acquisition.custom
            open Secret Project.mov
            open //storage/emulated/0/Private.mov
            error 42:/home/alice/private.mov
            /workspace/alice/Project|Acquisition.mov
            /workspace/alice/Project;Acquisition.mov
            '/workspace/alice/Project:2026;Acquisition.mov'
            /!Acquisition.mov
            "/!Acquisition.mov"
            "C:\\Users\\Alice Smith\\Private Draft.mp4"
            """,
            stack: """
            NSException: /Users/alice/Draft:99 in open()
            0   ViewerIOS   0x0000000104abcdef Player.open() + 42
            at Player.open() in /workspace/Élodie/src/Player.swift:42
            at "/home/alice/private:66" while opening file
            at file:///Users/alice/Player.swift:55
            at /Users/alice/Split.swift:line\rCaused by: /Users/alice/Cause:99
            at App.run()
            """
        )

        let json = try String(contentsOfFile: bufferPath, encoding: .utf8)
        let forbidden = [
            "alice", "smith", "lodie", "brien", "private", "secret", "abcdefghijkl",
            "acquisition", "project>.mov", "storage", "player.swift", "client).mov", "name.mov", "draft.mp4"
        ]
        for token in forbidden {
            #expect(!json.localizedCaseInsensitiveContains(token))
        }
        #expect(!json.contains(":99") && !json.contains(":66") && !json.contains(":55") && !json.contains("workspace"))
        #expect(json.contains("Player.open() + 42") && json.contains("App.run()") && json.contains("[redacted-path]"))
    }

    @Test("Re-enabling stays blocked until all pre-revocation flushes finish and purge")
    func reenableBlockedUntilMultipleRevokedFlushesDrain() async throws {
        let dir = try makeTempDir()
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

        let flush1 = Task { await service.flush() }
        await gate.waitForSlot(0)
        let flush2 = Task { await service.flush() }
        await gate.waitForSlot(1)

        // Opt out while BOTH pre-revocation flushes are active.
        #expect(service.setConsent(.off))
        #expect(!service.setConsent(.full))
        #expect(service.consent == .off)

        // Release slot 0 and deterministically await flush1 completion (including its defer cleanup);
        // flush2 is still gated at slot 1, so re-enable must remain blocked.
        gate.releaseSlot(0)
        await flush1.value
        #expect(!service.setConsent(.full))
        #expect(service.consent == .off)

        // Simulate late persist remnant before releasing flush2.
        try Data("{\"late\":true}".utf8).write(to: URL(fileURLWithPath: bufferPath))
        gate.releaseSlot(1)
        await flush2.value

        #expect(!FileManager.default.fileExists(atPath: bufferPath))
        #expect(service.setConsent(.full))
        #expect(service.consent == .full)
    }

    @Test("Re-enabling after a failed opt-out purge deletes leftover buffer before granting consent")
    func reenableAfterFailedPurgeDeletesLeftoverBufferFirst() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let restrictedDir = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: restrictedDir, withIntermediateDirectories: true)
        let bufferPath = restrictedDir.appendingPathComponent("telemetry-buffer.json").path

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
        service.track("screen_view", properties: ["screen": "revoked"])
        service.persist()
        #expect(FileManager.default.fileExists(atPath: bufferPath))

        // Make parent directory read-only so opt-out cannot unlink the buffer file.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: restrictedDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restrictedDir.path) }

        #expect(!service.setConsent(.off))
        #expect(service.lastPurgeFailed)
        #expect(FileManager.default.fileExists(atPath: bufferPath))

        // While buffer still cannot be purged, re-enable must fail closed.
        #expect(!service.setConsent(.full))
        #expect(service.consent == .off)
        #expect(service.lastPurgeFailed)

        // Restore permissions: re-enable must purge the stale revoked buffer FIRST so 0 old events reload.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restrictedDir.path)
        #expect(service.setConsent(.full))
        #expect(service.consent == .full)
        #expect(!service.lastPurgeFailed)
        #expect(service.pendingCount == 0)
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

@Suite("CoreTelemetryExternalConsent")
struct CoreTelemetryExternalConsentTests {
    @Test("Preserves valid RFC 3986 URLs and HTTP status lines while redacting local paths")
    func preservesValidRFC3986URLs() {
        let preserved = [
            "https://videos.api.alummahnow.net/v1/items",
            "https://example.com/?path=/api/items",
            "https://[2001:db8::1]/v1/items",
            "https://example.com/a(b)/items",
            "open(https://example.com/a(b)/items)",
            "https://example.com/a'b/items",
            "https://foo!bar.example/api",
            "git+http2://example.com/repo",
            "profile://example.com/repo",
            "https://[::1]:8443/api",
            "a123456789012345678901234567890123://example.com/repo",
            "HTTP/1.1 503 Service Unavailable",
        ]
        for item in preserved {
            #expect(CoreTelemetryService.sanitizeLocalPaths(item) == item)
        }
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com/api,open(C://Secret/Acquisition.mov)")
                == "https://example.com/api,open([redacted-path])"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("(https://example.com)(private/Secret.mov)")
                == "(https://example.com)([redacted-path])"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("https://example.com(/Users/alice/Secret.mov)")
                == "https://example.com([redacted-path])"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("open(/Volumes/Secret/Acquisition.mov) Player.open() + 42")
                == "open([redacted-path]) Player.open() + 42"
        )
        #expect(
            CoreTelemetryService.sanitizeLocalPaths("open Secret.mov from https://example.com/api")
                == "open [redacted-path] from https://example.com/api"
        )
        #expect(CoreTelemetryService.sanitizeLocalPaths("Secret Project.mov (missing)") == "[redacted-path] (missing)")
        #expect(CoreTelemetryService.sanitizeLocalPaths("Secret.Final.mov") == "[redacted-path]")
        #expect(CoreTelemetryService.sanitizeLocalPaths("Could not find file Secret.2026") == "Could not find file [redacted-path]")
        #expect(CoreTelemetryService.sanitizeLocalPaths("https://[:::]/api") != "https://[:::]/api")
        #expect(CoreTelemetryService.sanitizeLocalPaths("https://bad%zz/api") != "https://bad%zz/api")
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
}

import Foundation
import Testing

@testable import AUNCoreBridge

@Suite struct InjectionAuditTests {
    @Test func appLinkRejectsUserinfoAndTraversalSegments() {
        #expect(AppLink.parse(URL(string: "https://user:pass@videos.alummahnow.net/video/abc")!) == nil)
        #expect(AppLink.parse(URL(string: "https://videos.alummahnow.net/video/..")!) == nil)
        #expect(AppLink.parse(URL(string: "https://videos.alummahnow.net/video/%2e%2e")!) == nil)
        #expect(AppLink.parse(URL(string: "https://videos.alummahnow.net/@..")!) == nil)
        #expect(AppLink.parse(URL(string: "https://videos.alummahnow.net/studio/../admin")!) == nil)
        #expect(AppLink.parse(URL(string: "https://videos.alummahnow.net/video/vid_123")!) == .video(id: "vid_123"))
    }

    @Test func shortLinksRejectInvalidHostnameAndUserinfo() {
        #expect(ShortLinks.shortLinkOriginFor("https://user@videos.alummahnow.net") == nil)
        #expect(ShortLinks.shortLinkOriginFor("evil%20.alummahnow.link") == nil)
        #expect(ShortLinks.shortLinkOriginFor("https://videos.qa.alummahnow.net")?.absoluteString == "https://qa.alummahnow.link")
    }

    @Test func catalogServiceBlocksPathTraversalAndUnsafeSubtitleURL() async throws {
        let base = URL(string: "https://videos.api.qa.alummahnow.net")!
        let session = StubURLProtocol.session { _ in (200, [:], Data()) }
        let service = NativeCatalogService(baseURL: base, session: session)

        await #expect(throws: CoreError.notFound) { _ = try await service.video(id: "../admin/me") }
        await #expect(throws: CoreError.notFound) { _ = try await service.subtitles(videoID: "..") }
        await #expect(throws: CoreError.notFound) { _ = try await service.chapters(videoID: "v1?admin=1") }
        await #expect(throws: CoreError.forbidden) { _ = try await service.subtitleText(url: URL(string: "file:///etc/passwd")!) }
        await #expect(throws: CoreError.forbidden) {
            _ = try await service.subtitleText(url: URL(string: "http://evil.example/sub.vtt")!)
        }
    }

    @Test func liveServiceBlocksPathTraversal() async throws {
        let base = URL(string: "https://videos.api.qa.alummahnow.net")!
        let session = StubURLProtocol.session { _ in (200, [:], Data()) }
        let service = NativeLiveService(baseURL: base, session: session)

        await #expect(throws: CoreError.notFound) { _ = try await service.stream(id: "../secret") }
        await #expect(throws: CoreError.notFound) { _ = try await service.state(id: "..") }
        await #expect(throws: CoreError.notFound) { _ = try await service.beat(id: "a/b", viewerID: "v1", leaving: false) }
    }

    @Test func studioServiceBlocksPathTraversalAndHeaderInjection() async throws {
        let base = URL(string: "https://videos.api.qa.alummahnow.net")!
        let session = StubURLProtocol.session { _ in (200, [:], Data()) }
        let service = NativeStudioService(
            baseURL: base, accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]), session: session)

        await #expect(throws: CoreError.notFound) { _ = try await service.playlists(channelID: "../admin") }
        await #expect(throws: CoreError.notFound) { _ = try await service.resumeUpload(videoID: "..", channelID: "c1") }
        await #expect(throws: CoreError.notFound) {
            try await service.updateVideo(
                "v1/../../me", VideoEdit(title: "T", description: "", isPublic: true, tags: []), channelID: "c1")
        }
        await #expect(throws: CoreError.notFound) {
            try await service.hideCommentAuthor(userID: "u1", channelID: "../c", accountID: "a1")
        }
        await #expect(throws: CoreError.invalid("channelId")) {
            _ = try await service.client.request(.get, "/api/channels/access", channelID: "c1\r\nX-Injected: 1")
        }
    }

    @Test func reviewServiceRejectsInsecureBaseScheme() async throws {
        let session = StubURLProtocol.session { _ in (200, [:], Data()) }
        let review = NativeReviewService(
            adminAPI: URL(string: "ftp://localhost/admin")!, videosAPI: URL(string: "https://videos.api.qa.alummahnow.net")!,
            accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]), session: session)
        await #expect(throws: CoreError.forbidden) { _ = try await review.detail("r1") }
    }

    @Test func tusUploadAndTransferRejectCrossOriginLocationAndBadMetadataKeys() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "tus-inj-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let badLocationSession = StubURLProtocol.session { _ in
            (201, ["Location": "https://attacker.example/steal"], Data())
        }
        let engine = NativeTUSUploadEngine(
            session: badLocationSession, chunkSize: 1024, maxRetries: 0, retryDelay: .milliseconds(1))
        let dest = UploadDestination(endpoint: URL(string: "https://tus.test/files")!, headers: ["Authorization": "Bearer s"])
        await #expect(throws: CoreError.self) {
            _ = try await engine.upload(file: file, to: dest, resumeURL: nil, onCreated: { _ in }, onProgress: { _ in })
        }

        let badMetaDest = UploadDestination(
            endpoint: URL(string: "https://tus.test/files")!, metadata: ["bad,key": "val"])
        await #expect(throws: CoreError.self) {
            _ = try await engine.upload(file: file, to: badMetaDest, resumeURL: nil, onCreated: { _ in }, onProgress: { _ in })
        }

        let insecureDest = UploadDestination(endpoint: URL(string: "http://evil.example/files")!)
        await #expect(throws: CoreError.forbidden) {
            _ = try await engine.upload(file: file, to: insecureDest, resumeURL: nil, onCreated: { _ in }, onProgress: { _ in })
        }

        let transfer = TUSTransfer(chunkConfiguration: badLocationSession.configuration, control: badLocationSession)
        await #expect(throws: CoreError.self) {
            _ = try await transfer.create(
                endpoint: URL(string: "https://videos.api.qa.alummahnow.net/api/videos/tus")!,
                headers: ["Authorization": "Bearer t"], size: 5, metadata: ["tusSessionId": "s1"])
        }
        await #expect(throws: CoreError.self) {
            _ = try await transfer.create(
                endpoint: URL(string: "https://videos.api.qa.alummahnow.net/api/videos/tus")!,
                headers: [:], size: 5, metadata: ["bad key": "v"])
        }
        await #expect(throws: CoreError.forbidden) {
            _ = try await transfer.offset(of: URL(string: "http://evil.example/tus/1")!, headers: [:])
        }
    }

    @Test func encodePlannerAndContainedFileRejectTraversal() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "enc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plan = NativeEncodePlanner().plan(
            source: URL(fileURLWithPath: "/tmp/clip.mp4"),
            preset: EncodePreset(name: "../../evil", codec: .h264, maxHeight: 720, averageBitRate: 1_000_000),
            outputDirectory: dir)
        #expect(plan.destination.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path))

        #expect(SafeInput.resolveContainedFile(root: dir, relativePath: "../outside.mp4") == nil)
        #expect(SafeInput.resolveContainedFile(root: dir, relativePath: "/etc/passwd") == nil)
        #expect(SafeInput.resolveContainedFile(root: dir, relativePath: "720p/seg0.m4s") != nil)
    }

    @Test func safeExternalURLAndLogSanitizerWork() {
        #expect(SafeInput.isSafeExternalURL(URL(string: "https://alummahnow.net/help")!))
        #expect(SafeInput.isSafeExternalURL(URL(string: "http://localhost:8080/test")!))
        #expect(!SafeInput.isSafeExternalURL(URL(string: "javascript:alert(1)")!))
        #expect(!SafeInput.isSafeExternalURL(URL(string: "file:///etc/passwd")!))
        #expect(!SafeInput.isSafeExternalURL(URL(string: "http://example.com/phish")!))
        #expect(SafeInput.sanitizeLogLine("line1\r\nFAKE\u{2028}log") == "line1  FAKE log")
    }
}

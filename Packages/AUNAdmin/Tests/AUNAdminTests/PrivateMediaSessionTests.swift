import AUNCoreBridge
import Foundation
import Testing

/// Serves a cacheable response (public, one day) and lets URLSession store it if its configuration allows.
final class CacheableStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let headers = [
            "Content-Type": "image/jpeg", "Cache-Control": "public, max-age=86400",
            "Last-Modified": "Wed, 11 Nov 2026 10:00:00 GMT", "Content-Length": "\(Self.body.count)",
        ]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Owner rule: "never cache or download on phone or native app ever, only encrypted stream". Fails if a media
/// response from the Admin app's session lands in any URL cache or anywhere in the app's caches or temp folders.
@Suite(.serialized)
struct PrivateMediaSessionTests {
    private static let url = URL(string: "https://admin.api.qa.alummahnow.net/api/review/r1/media?key=review/v1/r1/frame.jpg")!

    private func marker() -> Data {
        var data = Data("AUN-PRIVATE-FRAME-".utf8)
        data.append(Data(UUID().uuidString.utf8))
        data.append(Data(repeating: 0xAB, count: 4096))
        return data
    }

    /// Every file under the folders an app may write to whose bytes contain the marker.
    /// Only files written since `since` are read: the folders may be large on a developer's Mac.
    private func filesContaining(_ needle: Data, since: Date) -> [URL] {
        let fm = FileManager.default
        var roots = [URL(fileURLWithPath: NSTemporaryDirectory())]
        for folder in fm.urls(for: .cachesDirectory, in: .userDomainMask)
            + fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        {
            // In a simulator or sandbox container the whole folder is this process's; on a plain Mac only its own part.
            if folder.path.contains("/CoreSimulator/") || folder.path.contains("/Containers/") {
                roots.append(folder)
            } else {
                for name in [Bundle.main.bundleIdentifier, "xctest", "swiftpm-testing-helper"].compactMap({ $0 }) {
                    roots.append(folder.appending(path: name))
                }
            }
        }
        let probe = needle.prefix(54)
        var hits: [URL] = []
        for root in roots {
            guard
                let walker = fm.enumerator(
                    at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
            else { continue }
            for case let file as URL in walker {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true, (values?.contentModificationDate ?? .distantFuture) >= since,
                    let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 64 * 1024 * 1024,
                    let data = try? Data(contentsOf: file, options: .mappedIfSafe)
                else { continue }
                if data.range(of: probe) != nil { hits.append(file) }
            }
        }
        return hits
    }

    @Test func theControlProvesACacheableResponseWouldBeStored() async throws {
        CacheableStub.body = marker()
        let folder = FileManager.default.temporaryDirectory.appending(path: "aun-control-\(UUID().uuidString)")
        let cache = URLCache(memoryCapacity: 0, diskCapacity: 50 * 1024 * 1024, directory: folder)
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.protocolClasses = [CacheableStub.self]
        let session = URLSession(configuration: config)
        _ = try await session.data(from: Self.url)
        var stored = cache.cachedResponse(for: URLRequest(url: Self.url)) != nil
        for _ in 0..<20 where !stored {
            try await Task.sleep(for: .milliseconds(100))
            stored = cache.cachedResponse(for: URLRequest(url: Self.url)) != nil
        }
        #expect(stored, "a default session caches this response, so the private-session test below means something")
        cache.removeAllCachedResponses()
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func mediaFromThePrivateSessionNeverLandsInACacheOrOnDisk() async throws {
        let started = Date().addingTimeInterval(-2)
        let body = marker()
        CacheableStub.body = body
        let session = PrivateMediaSession.make { $0.protocolClasses = [CacheableStub.self] }
        let (data, _) = try await session.data(for: PrivateMediaSession.request(Self.url))
        #expect(data == body)
        try await Task.sleep(for: .milliseconds(500))

        let config = session.configuration
        #expect(config.urlCache?.diskCapacity ?? 0 == 0)
        #expect(config.urlCache?.currentDiskUsage ?? 0 == 0)
        #expect(config.urlCache?.cachedResponse(for: URLRequest(url: Self.url)) == nil)
        #expect(URLCache.shared.cachedResponse(for: URLRequest(url: Self.url)) == nil)
        #expect(config.httpCookieStorage == nil)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        let leaked = filesContaining(body, since: started)
        #expect(leaked.isEmpty, "media bytes found on disk: \(leaked.map(\.path))")
    }

    @Test func theSharedSessionIsThePrivateOne() {
        let config = PrivateMediaSession.shared.configuration
        #expect(config.urlCache?.diskCapacity ?? 0 == 0)
        #expect(config.urlCache?.memoryCapacity ?? 0 == 0)
        #expect(config.httpCookieStorage == nil)
    }
}

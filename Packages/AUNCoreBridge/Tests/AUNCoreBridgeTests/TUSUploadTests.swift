import Foundation
import Testing

@testable import AUNCoreBridge

private final class FakeTUSServer: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var received = Data()
    private(set) var creates = 0
    private(set) var metadata: String?
    var failNextPatches = 0

    func seed(_ data: Data) { lock.withLock { received = data } }

    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            switch request.httpMethod {
            case "POST":
                creates += 1
                metadata = request.value(forHTTPHeaderField: "Upload-Metadata")
                return (201, ["Location": "/files/1"], Data())
            case "HEAD":
                return (200, ["Upload-Offset": String(received.count)], Data())
            default:
                if failNextPatches > 0 {
                    failNextPatches -= 1
                    return (500, [:], Data())
                }
                let offset = Int(request.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? -1
                guard offset == received.count else { return (409, [:], Data()) }
                received.append(body(request))
                return (204, ["Upload-Offset": String(received.count)], Data())
            }
        }
    }

    private func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private func tempFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try data.write(to: url)
    return url
}

private let endpoint = UploadDestination(
    endpoint: URL(string: "https://tus.test/files")!, headers: ["AuthorizationSignature": "sig"], metadata: ["title": "محاضرة"])

@Suite struct TUSUploadTests {
    private let payload = Data((0..<100).map { UInt8($0) })

    private func engine(_ server: FakeTUSServer) -> NativeTUSUploadEngine {
        NativeTUSUploadEngine(
            session: StubURLProtocol.session { server.handle($0) }, chunkSize: 30, maxRetries: 2, retryDelay: .milliseconds(1))
    }

    @Test func uploadsInChunksAndEncodesMetadata() async throws {
        let server = FakeTUSServer()
        let file = try tempFile(payload)
        let location = try await engine(server).upload(
            file: file, to: endpoint, resumeURL: nil, onCreated: { _ in }, onProgress: { _ in })
        #expect(server.received == payload)
        #expect(location.absoluteString == "https://tus.test/files/1")
        #expect(server.metadata == "title \(Data("محاضرة".utf8).base64EncodedString())")
    }

    @Test func resumesFromServerOffsetWithoutCreating() async throws {
        let server = FakeTUSServer()
        server.seed(payload.prefix(40))
        let file = try tempFile(payload)
        let resume = URL(string: "https://tus.test/files/1")
        _ = try await engine(server).upload(
            file: file, to: endpoint, resumeURL: resume, onCreated: { _ in }, onProgress: { _ in })
        #expect(server.creates == 0)
        #expect(server.received == payload)
    }

    @Test func retriesFailedPatch() async throws {
        let server = FakeTUSServer()
        server.failNextPatches = 2
        let file = try tempFile(payload)
        _ = try await engine(server).upload(file: file, to: endpoint, resumeURL: nil, onCreated: { _ in }, onProgress: { _ in })
        #expect(server.received == payload)
    }

    @Test func givesUpAfterMaxRetries() async throws {
        let server = FakeTUSServer()
        server.failNextPatches = 5
        let file = try tempFile(payload)
        await #expect(throws: CoreError.self) {
            _ = try await engine(server).upload(
                file: file, to: endpoint, resumeURL: nil, onCreated: { _ in }, onProgress: { _ in })
        }
    }
}

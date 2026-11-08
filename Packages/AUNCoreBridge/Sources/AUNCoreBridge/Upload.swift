import Foundation

public struct UploadDestination: Hashable, Sendable {
    public var endpoint: URL
    public var headers: [String: String]
    public var metadata: [String: String]

    public init(endpoint: URL, headers: [String: String] = [:], metadata: [String: String] = [:]) {
        self.endpoint = endpoint
        self.headers = headers
        self.metadata = metadata
    }
}

public struct UploadProgress: Hashable, Sendable {
    public var sent: Int64
    public var total: Int64
    public var fraction: Double { total > 0 ? Double(sent) / Double(total) : 0 }

    public init(sent: Int64, total: Int64) {
        self.sent = sent
        self.total = total
    }
}

/// Resumable upload. `aun-upload` replaces the native TUS implementation.
public protocol UploadEngine: Sendable {
    /// Uploads `file`, resuming from `resumeURL` when given. `onCreated` receives the URL to persist for resuming.
    func upload(
        file: URL, to destination: UploadDestination, resumeURL: URL?,
        onCreated: @Sendable (URL) async -> Void,
        onProgress: @Sendable (UploadProgress) async -> Void
    ) async throws -> URL
}

/// Minimal TUS 1.0 client: creation, offset discovery and chunked PATCH with retry.
public struct NativeTUSUploadEngine: UploadEngine {
    private let session: URLSession
    private let chunkSize: Int
    private let maxRetries: Int
    private let retryDelay: Duration

    public init(
        session: URLSession = .shared, chunkSize: Int = 8 * 1024 * 1024, maxRetries: Int = 3, retryDelay: Duration = .seconds(2)
    ) {
        self.session = session
        self.chunkSize = chunkSize
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
    }

    public func upload(
        file: URL, to destination: UploadDestination, resumeURL: URL?,
        onCreated: @Sendable (URL) async -> Void,
        onProgress: @Sendable (UploadProgress) async -> Void
    ) async throws -> URL {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize.map(Int64.init) else { throw CoreError.upload("unreadable file") }

        let location: URL
        var offset: Int64
        if let resumeURL, let current = try? await serverOffset(resumeURL, destination) {
            location = resumeURL
            offset = current
        } else {
            location = try await create(size: size, destination)
            offset = 0
            await onCreated(location)
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        await onProgress(UploadProgress(sent: offset, total: size))
        while offset < size {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw CoreError.upload("file ended early")
            }
            offset = try await patchWithRetry(location, chunk: chunk, offset: offset, destination)
            await onProgress(UploadProgress(sent: offset, total: size))
        }
        return location
    }

    private func request(_ url: URL, method: String, _ destination: UploadDestination) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        for (key, value) in destination.headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private func create(size: Int64, _ destination: UploadDestination) async throws -> URL {
        var request = request(destination.endpoint, method: "POST", destination)
        request.setValue(String(size), forHTTPHeaderField: "Upload-Length")
        if !destination.metadata.isEmpty {
            let encoded = destination.metadata.sorted { $0.key < $1.key }
                .map { "\($0.key) \(Data($0.value.utf8).base64EncodedString())" }.joined(separator: ",")
            request.setValue(encoded, forHTTPHeaderField: "Upload-Metadata")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201,
            let header = http.value(forHTTPHeaderField: "Location"),
            let location = URL(string: header, relativeTo: destination.endpoint)?.absoluteURL
        else { throw CoreError.upload("create failed") }
        return location
    }

    private func serverOffset(_ url: URL, _ destination: UploadDestination) async throws -> Int64 {
        let (_, response) = try await session.data(for: request(url, method: "HEAD", destination))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let offset = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init)
        else { throw CoreError.upload("offset unavailable") }
        return offset
    }

    private func patchWithRetry(_ url: URL, chunk: Data, offset: Int64, _ destination: UploadDestination) async throws -> Int64 {
        var attempt = 0
        var currentOffset = offset
        while true {
            do {
                let sent = chunk.dropFirst(Int(currentOffset - offset))
                return try await patch(url, chunk: Data(sent), offset: currentOffset, destination)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                guard attempt <= maxRetries else { throw error }
                AUNLog.studio.warning("TUS PATCH retry \(attempt)")
                try await Task.sleep(for: retryDelay)
                let server = try await serverOffset(url, destination)
                if server >= offset + Int64(chunk.count) { return server }
                currentOffset = max(server, offset)
            }
        }
    }

    private func patch(_ url: URL, chunk: Data, offset: Int64, _ destination: UploadDestination) async throws -> Int64 {
        var request = request(url, method: "PATCH", destination)
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        let (_, response) = try await session.upload(for: request, from: chunk)
        guard let http = response as? HTTPURLResponse, http.statusCode == 204,
            let next = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init)
        else { throw CoreError.upload("patch failed") }
        return next
    }
}

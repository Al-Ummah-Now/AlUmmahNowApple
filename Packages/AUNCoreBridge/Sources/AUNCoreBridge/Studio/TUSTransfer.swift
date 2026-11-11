import Foundation

/// The TUS steps the upload queue uses. `TUSTransfer` is the live one.
public protocol TUSTransferring: AnyObject, Sendable {
    var onOrphanCompletion: (@Sendable () -> Void)? { get set }
    func create(endpoint: URL, headers: [String: String], size: Int64, metadata: [String: String]) async throws -> URL
    func offset(of url: URL, headers: [String: String]) async throws -> Int64
    func send(
        chunk file: URL, to url: URL, offset: Int64, headers: [String: String],
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64
}

/// Accepts every chunk after a short pause, for UI tests and previews.
public final class FixtureTUSTransfer: TUSTransferring, @unchecked Sendable {
    public var onOrphanCompletion: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var sizes: [URL: Int64] = [:]
    private let delay: Duration

    public init(delay: Duration = .milliseconds(300)) { self.delay = delay }

    public func create(endpoint: URL, headers: [String: String], size: Int64, metadata: [String: String]) async throws -> URL {
        endpoint.appending(path: UUID().uuidString)
    }

    public func offset(of url: URL, headers: [String: String]) async throws -> Int64 { lock.withLock { sizes[url] ?? 0 } }

    public func send(
        chunk file: URL, to url: URL, offset: Int64, headers: [String: String],
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        // URL resource values are cached per URL, and the chunk file is rewritten for every chunk.
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path())[.size]) as? NSNumber)?.int64Value ?? 0
        progress(size / 2)
        try await Task.sleep(for: delay)
        progress(size)
        return lock.withLock {
            sizes[url] = offset + size
            return offset + size
        }
    }
}

/// TUS 1.0 against the api-videos proxy, one chunk per PATCH. Each chunk is sent from a file, so a background
/// URLSession can carry it while the app is suspended; create and HEAD go over a normal session.
public final class TUSTransfer: NSObject, TUSTransferring, URLSessionTaskDelegate, @unchecked Sendable {
    /// The identifier of the iOS background session for uploads.
    public static let backgroundIdentifier = "net.alummahnow.studio.uploads"

    private let control: URLSession
    private var chunks: URLSession!
    private let lock = NSLock()
    private var waiting: [Int: CheckedContinuation<HTTPURLResponse, any Error>] = [:]
    private var progress: [Int: @Sendable (Int64) -> Void] = [:]
    private var finishEvents: (@Sendable () -> Void)?
    /// Called when a chunk finished that nobody awaits any more (the app was relaunched in the background).
    public var onOrphanCompletion: (@Sendable () -> Void)?

    /// `chunkConfiguration` is `.background(withIdentifier:)` on iOS; tests pass an ephemeral one.
    public init(chunkConfiguration: URLSessionConfiguration, control: URLSession = .shared) {
        self.control = control
        super.init()
        chunks = URLSession(configuration: chunkConfiguration, delegate: self, delegateQueue: nil)
    }

    /// The live transfer for this platform.
    public static func live() -> TUSTransfer {
        #if os(iOS)
            let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
        #else
            let configuration = URLSessionConfiguration.default
        #endif
        configuration.timeoutIntervalForRequest = 120
        return TUSTransfer(chunkConfiguration: configuration)
    }

    /// Keeps the completion handler iOS gives when it relaunches the app for upload events.
    public func handleBackgroundEvents(_ completion: @escaping @Sendable () -> Void) {
        lock.withLock { finishEvents = completion }
    }

    private func request(_ url: URL, _ method: String, _ headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private static func check(_ response: URLResponse?) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw CoreError.upload("no response") }
        switch http.statusCode {
        case 200..<300: return http
        case 401: throw CoreError.signInRequired
        case 403: throw CoreError.forbidden
        case 404, 410: throw CoreError.notFound
        default: throw CoreError.http(status: http.statusCode)
        }
    }

    /// Creates the upload; returns its URL.
    public func create(endpoint: URL, headers: [String: String], size: Int64, metadata: [String: String]) async throws -> URL {
        var request = request(endpoint, "POST", headers)
        request.setValue(String(size), forHTTPHeaderField: "Upload-Length")
        let encoded = metadata.sorted { $0.key < $1.key }
            .map { "\($0.key) \(Data($0.value.utf8).base64EncodedString())" }.joined(separator: ",")
        request.setValue(encoded, forHTTPHeaderField: "Upload-Metadata")
        let (_, response) = try await control.data(for: request)
        let http = try Self.check(response)
        guard let header = http.value(forHTTPHeaderField: "Location"),
            let location = URL(string: header, relativeTo: endpoint)?.absoluteURL
        else { throw CoreError.upload("no Location") }
        guard location.scheme == "https" || endpoint.scheme != "https" else { throw CoreError.upload("insecure Location") }
        return location
    }

    /// How many bytes the server has.
    public func offset(of url: URL, headers: [String: String]) async throws -> Int64 {
        let (_, response) = try await control.data(for: request(url, "HEAD", headers))
        let http = try Self.check(response)
        guard let offset = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init) else {
            throw CoreError.upload("no Upload-Offset")
        }
        return offset
    }

    /// Sends one chunk (the whole of `file`) at `offset`; returns the server's new offset.
    public func send(
        chunk file: URL, to url: URL, offset: Int64, headers: [String: String],
        progress onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        var request = request(url, "PATCH", headers)
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        let task = chunks.uploadTask(with: request, fromFile: file)
        task.taskDescription = url.absoluteString
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    waiting[task.taskIdentifier] = continuation
                    progress[task.taskIdentifier] = onProgress
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        let http = try Self.check(response)
        guard let next = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init) else {
            throw CoreError.upload("no Upload-Offset")
        }
        return next
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let handler = lock.withLock { progress[task.taskIdentifier] }
        handler?(totalBytesSent)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = lock.withLock {
            progress[task.taskIdentifier] = nil
            return waiting.removeValue(forKey: task.taskIdentifier)
        }
        guard let continuation else {
            onOrphanCompletion?()
            return
        }
        if let error {
            continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else if let http = task.response as? HTTPURLResponse {
            continuation.resume(returning: http)
        } else {
            continuation.resume(throwing: CoreError.upload("no response"))
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            defer { finishEvents = nil }
            return finishEvents
        }
        DispatchQueue.main.async { completion?() }
    }
}

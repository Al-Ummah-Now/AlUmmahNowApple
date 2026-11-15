import AUNCoreBridge
import Foundation

/// Sends renditions encoded on this computer (D11): declare every file, PUT each one, complete. Never throws: whatever
/// goes wrong, the original upload carries on and the server encodes the video as usual.
public struct RenditionUploader: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The renditions wait for the original upload; the server verifies them before use.
        case ready
        /// The server already started encoding (`too_late`): nothing to do.
        case tooLate
        case cancelled
        /// Something failed; the server encodes instead. The detail is for the log.
        case failed(String)
    }

    public struct Progress: Equatable, Sendable {
        public var filesDone: Int
        public var filesTotal: Int
        public var bytesDone: Int64
        public var bytesTotal: Int64
        public var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0 }
    }

    let service: any RenditionsServicing
    let videoID: String
    let channelID: String?
    let root: URL
    let rungs: [String]
    let files: [StagedFile]
    let encoder: String
    /// How a file's bytes are read; tests read from memory.
    var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    /// Waits between retries; tests skip it.
    var pause: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Attempts per request for errors worth retrying (offline, 5xx).
    var attempts = 3

    public init(
        service: any RenditionsServicing, videoID: String, channelID: String?, root: URL, rungs: [String],
        files: [StagedFile], encoder: String
    ) {
        self.service = service
        self.videoID = videoID
        self.channelID = channelID
        self.root = root
        self.rungs = rungs
        self.files = files
        self.encoder = encoder
    }

    public func run(progress: @escaping @Sendable (Progress) async -> Void = { _ in }) async -> Outcome {
        let staging: RenditionStaging
        do {
            staging = try await retrying {
                try await service.createRenditions(
                    videoID: videoID, rungs: rungs, files: files, encoder: encoder, channelID: channelID)
            }
        } catch {
            return outcome(error)
        }
        let result = await send(staging, progress: progress)
        if result != .ready, result != .tooLate {
            // Best effort: the server drops stale staging on its own too.
            try? await service.cancelRenditions(videoID: videoID, stagingID: staging.stagingID, channelID: channelID)
        }
        return result
    }

    private func send(_ staging: RenditionStaging, progress: @escaping @Sendable (Progress) async -> Void) async -> Outcome {
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        var state = Progress(filesDone: 0, filesTotal: files.count, bytesDone: 0, bytesTotal: total)
        do {
            if let limit = staging.maxFileBytes, let large = files.first(where: { $0.bytes > limit }) {
                return .failed("\(large.path) is over the server's file limit")
            }
            for file in files {
                try await put(file, staging)
                state.filesDone += 1
                state.bytesDone += file.bytes
                await progress(state)
            }
            // `files_missing` lists files the server lacks (a lost PUT): send those again, twice at most.
            for round in 0...2 {
                do {
                    try await retrying {
                        try await service.completeRenditions(
                            videoID: videoID, stagingID: staging.stagingID, channelID: channelID)
                    }
                    return .ready
                } catch CoreError.conflict("files_missing", let missing) where round < 2 && !missing.isEmpty {
                    for path in missing {
                        guard let file = files.first(where: { $0.path == path }) else { return .failed("unknown \(path)") }
                        try await put(file, staging)
                    }
                }
            }
            return .failed("files still missing")
        } catch {
            return outcome(error)
        }
    }

    private func put(_ file: StagedFile, _ staging: RenditionStaging) async throws {
        try Task.checkCancellation()
        let bytes = try read(root.appending(path: file.path))
        try await retrying {
            try await service.putRenditionFile(
                videoID: videoID, stagingID: staging.stagingID, file: file, bytes: bytes, channelID: channelID)
        }
    }

    /// Retries offline and 5xx answers with 2 s, 4 s… between attempts. Everything else is final.
    private func retrying<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await body()
            } catch let error as CoreError where attempt < attempts && Self.isTransient(error) {
                try await pause(.seconds(1 << attempt))
                attempt += 1
            }
        }
    }

    static func isTransient(_ error: CoreError) -> Bool {
        switch error {
        case .offline: true
        case .http(let status): status >= 500 || status == 429
        default: false
        }
    }

    private func outcome(_ error: any Error) -> Outcome {
        if error is CancellationError || (error as? CoreError) == .cancelled { return .cancelled }
        if case .conflict("too_late", _) = error as? CoreError { return .tooLate }
        return .failed(String(describing: error))
    }
}

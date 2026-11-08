import AUNCoreBridge
import Foundation
import Observation

/// Supplies where each file goes. Calls the upload-initiate API after sign-in (Epic 9).
public protocol UploadDestinationProviding: Sendable {
    func destination(for file: URL) async throws -> UploadDestination
}

/// Used until a native OAuth client is registered. It never uploads.
public struct SignInRequiredDestinationProvider: UploadDestinationProviding {
    public init() {}
    public func destination(for file: URL) async throws -> UploadDestination { throw CoreError.signInRequired }
}

public enum QueueItemStatus: Hashable, Sendable {
    case waiting, running, done, failed
}

public struct UploadQueueItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let file: URL
    public var status: QueueItemStatus = .waiting
    public var fraction: Double = 0
    public var resumeURL: URL?

    init(file: URL) {
        id = UUID()
        self.file = file
    }
}

@MainActor @Observable
public final class BatchUploadQueue {
    public private(set) var items: [UploadQueueItem] = []
    public private(set) var needsSignIn = false
    public private(set) var isRunning = false

    private let engine: any UploadEngine
    private let destinations: any UploadDestinationProviding
    private let maxParallel: Int

    public init(engine: any UploadEngine, destinations: any UploadDestinationProviding, maxParallel: Int = 2) {
        self.engine = engine
        self.destinations = destinations
        self.maxParallel = maxParallel
    }

    public func add(_ files: [URL]) {
        var seen = Set(items.map(\.file))
        items += files.filter { seen.insert($0).inserted }.map(UploadQueueItem.init(file:))
    }

    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        needsSignIn = false
        defer { isRunning = false }
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for id in items.filter({ $0.status != .done }).map(\.id) {
                if active == maxParallel {
                    await group.next()
                    active -= 1
                }
                group.addTask { await self.upload(id) }
                active += 1
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout UploadQueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func upload(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        update(id) { $0.status = .running }
        let accessing = item.file.startAccessingSecurityScopedResource()
        defer { if accessing { item.file.stopAccessingSecurityScopedResource() } }
        do {
            let destination = try await destinations.destination(for: item.file)
            _ = try await engine.upload(
                file: item.file, to: destination, resumeURL: item.resumeURL,
                onCreated: { url in await self.update(id) { $0.resumeURL = url } },
                onProgress: { progress in await self.update(id) { $0.fraction = progress.fraction } })
            update(id) { $0.status = .done }
        } catch CoreError.signInRequired {
            needsSignIn = true
            update(id) { $0.status = .waiting }
        } catch {
            AUNLog.studio.error("Upload failed: \(error)")
            update(id) { $0.status = .failed }
        }
    }
}

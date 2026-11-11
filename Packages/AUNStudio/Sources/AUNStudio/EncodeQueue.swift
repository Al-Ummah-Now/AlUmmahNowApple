import AUNCoreBridge
import Foundation
import Observation

public enum QueueItemStatus: Hashable, Sendable {
    case waiting, running, done, failed
}

public struct EncodeQueueItem: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let source: URL
    public var status: QueueItemStatus = .waiting
    public var fraction: Double = 0
    public var usedHardware: Bool?
    public var output: URL?
}

/// Encodes one file at a time, so a long batch doesn't saturate the media engine.
@MainActor @Observable
public final class EncodeQueue {
    public private(set) var items: [EncodeQueueItem] = []
    public private(set) var isRunning = false
    private let planner: any EncodePlanning
    private let encoder = VideoToolboxEncoder()
    private let outputDirectory: URL
    private var task: Task<Void, Never>?

    public init(planner: any EncodePlanning = NativeEncodePlanner(), outputDirectory: URL) {
        self.planner = planner
        self.outputDirectory = outputDirectory
    }

    public func add(_ sources: [URL]) {
        items += sources.map { EncodeQueueItem(source: $0) }
    }

    public func start(preset: EncodePreset = .lecture) {
        guard !isRunning else { return }
        isRunning = true
        task = Task { [weak self] in
            await self?.drain(preset)
            self?.isRunning = false
        }
    }

    public func cancel() { task?.cancel() }

    public func waitUntilFinished() async { await task?.value }

    private func update(_ id: UUID, _ change: (inout EncodeQueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func drain(_ preset: EncodePreset) async {
        while !Task.isCancelled, let item = items.first(where: { $0.status == .waiting }) {
            update(item.id) { $0.status = .running }
            let accessing = item.source.startAccessingSecurityScopedResource()
            defer { if accessing { item.source.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                let plan = planner.plan(source: item.source, preset: preset, outputDirectory: outputDirectory)
                let id = item.id
                let outcome = try await encoder.encode(plan) { fraction in
                    await self.update(id) { $0.fraction = fraction }
                }
                update(item.id) {
                    $0.status = .done
                    $0.fraction = 1
                    $0.usedHardware = outcome.usedHardware
                    $0.output = outcome.output
                }
            } catch {
                AUNLog.studio.error("Encode failed: \(error)")
                update(item.id) { $0.status = .failed }
            }
        }
    }
}

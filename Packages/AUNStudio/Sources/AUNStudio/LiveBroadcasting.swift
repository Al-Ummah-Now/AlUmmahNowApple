import Foundation

public struct LiveIngestConfiguration: Hashable, Sendable {
    public enum Transport: String, Sendable { case rtmp, srt }
    public var transport: Transport
    public var url: URL
    public var streamKey: String

    public init(transport: Transport, url: URL, streamKey: String) {
        self.transport = transport
        self.url = url
        self.streamKey = streamKey
    }
}

public struct LiveHealth: Hashable, Sendable {
    public var bitrate: Int
    public var droppedFrames: Int

    public init(bitrate: Int, droppedFrames: Int) {
        self.bitrate = bitrate
        self.droppedFrames = droppedFrames
    }
}

public enum LiveBroadcastError: Error, Sendable { case providerUndecided }

/// Go Live seam (spec 18.7). The adapter arrives once decision D3 picks a provider. See docs/research/live-broadcast.md.
public protocol LiveBroadcasting: Sendable {
    var isAvailable: Bool { get }
    func start(_ configuration: LiveIngestConfiguration) async throws
    func stop() async
    func health() async -> LiveHealth?
}

public struct UnavailableLiveBroadcaster: LiveBroadcasting {
    public init() {}
    public var isAvailable: Bool { false }
    public func start(_ configuration: LiveIngestConfiguration) async throws { throw LiveBroadcastError.providerUndecided }
    public func stop() async {}
    public func health() async -> LiveHealth? { nil }
}

import AUNCoreBridge
import Foundation
import Observation

/// The Dashboard's sections for one channel: recent uploads with their processing status, comments awaiting review,
/// and drafts and scheduled videos. Each loads on its own and ends in content, an empty state or hidden; when every
/// section is hidden the Dashboard has nothing to show and Studio opens on Content instead.
@MainActor @Observable
final class DashboardModel {
    /// How many rows each section lists.
    static let rows = 4

    private(set) var recent: [StudioVideo] = []
    private(set) var recentPhase: LoadPhase = .idle
    private(set) var held = HeldComments(items: [], total: 0)
    private(set) var heldPhase: LoadPhase
    private(set) var drafts: [StudioVideo] = []
    private(set) var scheduled: [StudioVideo] = []
    private(set) var counts: ContentCounts = [:]
    private(set) var queuePhase: LoadPhase = .idle

    let channel: StudioChannel
    let services: StudioServices
    /// Told when every section turned out hidden.
    @ObservationIgnored var onHollow: (() -> Void)?
    /// Told when a section's API answered that its feature is off, so Studio reads its features again.
    @ObservationIgnored var onFeatureOff: (() -> Void)?

    init(channel: StudioChannel, services: StudioServices) {
        self.channel = channel
        self.services = services
        // Comments are reviewed by the channel's owner, admins and moderators only.
        heldPhase = channel.can("comment.moderate") ? .idle : .hidden
    }

    /// Every section hidden: nothing left on the Dashboard.
    var isHollow: Bool { [recentPhase, heldPhase, queuePhase].allSatisfy { $0 == .hidden } }

    func load() async {
        async let recent: Void = loadRecent()
        async let held: Void = loadHeld()
        async let queue: Void = loadQueue()
        _ = await (recent, held, queue)
        if isHollow { onHollow?() }
    }

    /// The newest uploads still processing, failed or published, newest first.
    func loadRecent() async {
        await LoadPhase.run(from: recentPhase, set: { recentPhase = $0 }) {
            let studio = services.studio
            let id = channel.id
            async let processing = studio.content(channelID: id, query: Self.query(.processing), cursor: nil)
            async let failed = studio.content(channelID: id, query: Self.query(.failed), cursor: nil)
            async let published = studio.content(channelID: id, query: Self.query(.published), cursor: nil)
            let all = try await processing.items + failed.items + published.items
            recent = Array(all.sorted { ($0.dateCreated ?? .distantPast) > ($1.dateCreated ?? .distantPast) }.prefix(Self.rows))
            return recent.isEmpty
        }
        reportOff(recentPhase)
    }

    func loadHeld() async {
        guard heldPhase != .hidden else { return }
        await LoadPhase.run(from: heldPhase, set: { heldPhase = $0 }) {
            held = try await services.studio.heldComments(channelID: channel.id, limit: Self.rows)
            return held.total == 0 && held.items.isEmpty
        }
        reportOff(heldPhase)
    }

    func loadQueue() async {
        await LoadPhase.run(from: queuePhase, set: { queuePhase = $0 }) {
            let studio = services.studio
            let id = channel.id
            async let drafts = studio.content(channelID: id, query: Self.query(.drafts), cursor: nil)
            async let scheduled = studio.content(channelID: id, query: Self.query(.scheduled), cursor: nil)
            async let counts = studio.contentCounts(channelID: id)
            self.drafts = try await drafts.items
            self.scheduled = try await scheduled.items
            self.counts = (try? await counts) ?? [:]
            return self.drafts.isEmpty && self.scheduled.isEmpty
        }
        reportOff(queuePhase)
    }

    private func reportOff(_ phase: LoadPhase) {
        if phase == .hidden { onFeatureOff?() }
    }

    static func query(_ status: StudioStatus) -> ContentQuery {
        ContentQuery(status: status, sort: .newest, limit: rows)
    }
}

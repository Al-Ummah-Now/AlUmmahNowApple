import Foundation

/// Where the last video stopped, so it survives the system ending the app at any moment (Screen Time's App Limits and
/// Downtime, memory pressure, a force quit). One entry, on this device only; never sent anywhere.
@MainActor
public final class PlaybackPositionStore {
    /// How long a position is worth coming back to.
    nonisolated static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    /// Too close to the start or the end to resume from.
    nonisolated static let margin: Double = 10

    private struct Entry: Codable {
        var videoID: String
        var seconds: Double
        var savedAt: Date
    }

    private let defaults: UserDefaults
    private let key = "player.lastPosition"
    private let now: () -> Date

    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now }) {
        self.defaults = defaults
        self.now = now
    }

    /// Where to resume this video, or nil to start at the beginning.
    public func position(of videoID: String) -> Double? {
        guard let entry = entry(), entry.videoID == videoID else { return nil }
        let age = now().timeIntervalSince(entry.savedAt)
        guard age >= 0, age < Self.lifetime, entry.seconds.isFinite, entry.seconds >= Self.margin else { return nil }
        return entry.seconds
    }

    /// Keeps the position, or forgets the video when it is as good as finished or not really started.
    public func save(_ seconds: Double, duration: Double, of videoID: String) {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        guard seconds >= Self.margin, seconds < duration - Self.margin else {
            if entry()?.videoID == videoID { defaults.removeObject(forKey: key) }
            return
        }
        let entry = Entry(videoID: videoID, seconds: seconds, savedAt: now())
        if let data = try? JSONEncoder().encode(entry) { defaults.set(data, forKey: key) }
    }

    private func entry() -> Entry? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
    }
}

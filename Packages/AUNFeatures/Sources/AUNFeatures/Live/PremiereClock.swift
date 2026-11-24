import Foundation

/// Where a premiere is (wiki E17 §5.4): everyone sees the same moment, by the server's clock.
struct PremiereClock: Hashable, Sendable {
    var startedAt: Date
    /// How far the server's clock is ahead of this device's.
    var offset: TimeInterval
    var duration: Double?

    /// Seconds into the video now, between 0 and its length.
    func position(at now: Date) -> Double {
        let seconds = max(0, now.timeIntervalSince(startedAt) + offset)
        return duration.map { min(seconds, $0) } ?? seconds
    }

    func isOver(at now: Date) -> Bool { duration.map { position(at: now) >= $0 } ?? false }
}

/// Keeps a player at the premiere's moment. A viewer may pause or go back: they are then behind, until they catch up
/// or return. Going ahead is not possible, and neither is playing faster than everyone else while at the moment.
struct PremiereFollower: Sendable {
    /// Further from the moment than this, playback is brought back to it.
    static let resyncSeconds = 3.0
    /// Nobody gets ahead of it by more than the jitter of a seek.
    static let aheadSeconds = 1.0

    /// What the player is doing at one tick.
    struct Reading: Sendable {
        var moment: Double
        var time: Double
        var isPlaying: Bool
        /// Enough is loaded to go on: otherwise another seek would only make it start over.
        var canKeepUp: Bool
        var speed: Float
    }

    enum Action: Equatable, Sendable {
        case seek(Double)
        case normalSpeed
    }

    private(set) var isFollowing = true
    private(set) var isBehind = false
    private var hasPlayed = false
    private var lastTime: Double?

    mutating func returned() {
        isFollowing = true
        isBehind = false
        lastTime = nil
    }

    mutating func tick(_ reading: Reading) -> [Action] {
        let drift = reading.moment - reading.time
        var actions: [Action] = []
        defer { isBehind = !isFollowing && drift > Self.resyncSeconds }
        // Back further than playing explains: the viewer went there
        if hasPlayed, let lastTime, reading.time < lastTime - Self.aheadSeconds, drift > Self.resyncSeconds {
            isFollowing = false
        }
        lastTime = reading.time
        if drift < -Self.aheadSeconds {
            isFollowing = true
            lastTime = reading.moment
            return [.seek(reading.moment)]
        }
        guard reading.isPlaying else {
            if hasPlayed { isFollowing = false }
            return []
        }
        hasPlayed = true
        if !isFollowing, abs(drift) <= Self.aheadSeconds { isFollowing = true }
        guard isFollowing else { return [] }
        if reading.speed != 1 { actions.append(.normalSpeed) }
        if reading.canKeepUp, abs(drift) > Self.resyncSeconds {
            lastTime = reading.moment
            actions.append(.seek(reading.moment))
        }
        return actions
    }
}

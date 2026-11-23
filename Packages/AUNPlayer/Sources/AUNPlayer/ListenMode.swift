import AVFoundation
import Foundation
import Observation

/// Sleep timer presets for Listen mode (Epic 14).
public enum SleepTimerPreset: Hashable, Sendable {
    case off
    case minutes(Int)
    case endOfEpisode

    public static let standard: [SleepTimerPreset] = [
        .off,
        .minutes(15),
        .minutes(30),
        .minutes(45),
        .minutes(60),
        .endOfEpisode,
    ]
}

public struct SleepTimerState: Hashable, Sendable {
    public var preset: SleepTimerPreset = .off
    public var expiresAt: Date?

    public var isActive: Bool { preset != .off }

    public func remainingSeconds(at now: Date) -> TimeInterval? {
        guard case .minutes = preset, let expiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSince(now))
    }

    public func isExpired(at now: Date) -> Bool {
        guard case .minutes = preset, let expiresAt else { return false }
        return now >= expiresAt
    }

    public init(preset: SleepTimerPreset = .off, expiresAt: Date? = nil) {
        self.preset = preset
        self.expiresAt = expiresAt
    }
}

public struct QueueEntry: Identifiable, Hashable, Sendable {
    public var id: String { videoId }
    public var videoId: String
    public var playbackItem: PlaybackItem
    public var audioURL: URL?
    public var durationSeconds: Double?

    public init(videoId: String, playbackItem: PlaybackItem, audioURL: URL? = nil, durationSeconds: Double? = nil) {
        self.videoId = videoId
        self.playbackItem = playbackItem
        self.audioURL = audioURL
        self.durationSeconds = durationSeconds
    }
}

/// Manages Listen mode (audio-only playback), sleep timer, and up-next queue across iOS, macOS, and tvOS.
/// Gated by the server's `listenMode` feature switch (defaults OFF).
@MainActor @Observable
public final class ListenModeManager {
    public private(set) var listenModeEnabled: Bool
    public private(set) var isAudioOnly: Bool = false
    public private(set) var sleepTimer = SleepTimerState()
    public private(set) var queue: [QueueEntry] = []
    public private(set) var currentIndex: Int = -1

    public var currentEntry: QueueEntry? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    public var upNext: [QueueEntry] {
        guard queue.indices.contains(currentIndex) else { return queue }
        return Array(queue.dropFirst(currentIndex + 1))
    }

    private let now: @Sendable () -> Date

    public init(listenModeEnabled: Bool = false, now: @escaping @Sendable () -> Date = Date.init) {
        self.listenModeEnabled = listenModeEnabled
        self.now = now
    }

    public func setFeatureEnabled(_ enabled: Bool) {
        listenModeEnabled = enabled
        if !enabled {
            isAudioOnly = false
            sleepTimer = SleepTimerState()
        }
    }

    /// Switches between Video and Listen (audio-only) modes, preserving current position, speed, and playing state.
    public func setAudioOnly(_ enabled: Bool, controller: PlayerController? = nil) {
        if enabled && !listenModeEnabled { return }
        guard isAudioOnly != enabled else { return }
        isAudioOnly = enabled

        guard let controller else { return }
        #if os(iOS) || os(tvOS)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: enabled ? .spokenAudio : .moviePlayback)
                try session.setActive(true)
            } catch {
                // Best-effort mode hint; playback continues regardless.
            }
        #endif

        // If an audio-only rendition URL is available, swap streams cleanly at the same timestamp & speed.
        if let entry = currentEntry, let audioURL = entry.audioURL {
            let resumeTime = controller.currentTime
            let wasPlaying = controller.isPlaying
            let savedSpeed = controller.speed
            var target = entry.playbackItem
            target.url = enabled ? audioURL : entry.playbackItem.url
            controller.load(target, autoplay: false)
            controller.setSpeed(savedSpeed)
            if resumeTime > 0 { controller.seek(to: resumeTime) }
            if wasPlaying { controller.play() }
        }
    }

    public func setSleepTimer(_ preset: SleepTimerPreset) {
        switch preset {
        case .off:
            sleepTimer = SleepTimerState(preset: .off, expiresAt: nil)
        case .endOfEpisode:
            sleepTimer = SleepTimerState(preset: .endOfEpisode, expiresAt: nil)
        case .minutes(let mins):
            let clamped = max(1, mins)
            sleepTimer = SleepTimerState(preset: .minutes(clamped), expiresAt: now().addingTimeInterval(Double(clamped) * 60))
        }
    }

    public func cancelSleepTimer() { setSleepTimer(.off) }

    /// Evaluates timed sleep timer; pauses `controller` and returns true when expired.
    @discardableResult
    public func tickSleepTimer(controller: PlayerController? = nil) -> Bool {
        guard sleepTimer.isExpired(at: now()) else { return false }
        sleepTimer = SleepTimerState()
        controller?.pause()
        return true
    }

    /// Evaluates end-of-episode sleep timer when an item finishes; returns true if playback was paused.
    @discardableResult
    public func handleEpisodeEnded(controller: PlayerController? = nil) -> Bool {
        guard sleepTimer.preset == .endOfEpisode else { return false }
        sleepTimer = SleepTimerState()
        controller?.pause()
        return true
    }

    public func setNowPlaying(_ entry: QueueEntry) {
        if let idx = queue.firstIndex(where: { $0.videoId == entry.videoId }) {
            currentIndex = idx
        } else {
            queue.insert(entry, at: 0)
            currentIndex = 0
        }
    }

    public func playNext(_ entry: QueueEntry) {
        queue.removeAll { $0.videoId == entry.videoId }
        let insertAt = currentIndex >= 0 ? min(currentIndex + 1, queue.count) : 0
        queue.insert(entry, at: insertAt)
    }

    public func addToEnd(_ entry: QueueEntry) {
        guard !queue.contains(where: { $0.videoId == entry.videoId }) else { return }
        queue.append(entry)
    }

    public func removeFromQueue(videoId: String) {
        guard let idx = queue.firstIndex(where: { $0.videoId == videoId }) else { return }
        queue.remove(at: idx)
        if queue.isEmpty {
            currentIndex = -1
        } else if idx < currentIndex {
            currentIndex -= 1
        } else if idx == currentIndex {
            currentIndex = min(currentIndex, queue.count - 1)
        }
    }

    public func moveQueueItem(from source: Int, to destination: Int) {
        guard queue.indices.contains(source), queue.indices.contains(destination), source != destination else { return }
        let activeId = currentEntry?.videoId
        let item = queue.remove(at: source)
        queue.insert(item, at: destination)
        if let activeId, let newIdx = queue.firstIndex(where: { $0.videoId == activeId }) {
            currentIndex = newIdx
        }
    }

    @discardableResult
    public func advance() -> QueueEntry? {
        let next = currentIndex + 1
        guard queue.indices.contains(next) else { return nil }
        currentIndex = next
        return queue[next]
    }

    public func clearUpNext() {
        if let current = currentEntry {
            queue = [current]
            currentIndex = 0
        } else {
            queue = []
            currentIndex = -1
        }
    }
}

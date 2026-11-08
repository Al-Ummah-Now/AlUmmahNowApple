import AUNCoreBridge
import AVFoundation
import Combine
import CoreMedia
import Observation

public struct PlaybackItem: Hashable, Sendable {
    public var url: URL
    public var title: String
    public var subtitle: String?
    public var resolutions: [String]
    public var subtitles: [SubtitleTrack]
    public var chapters: [Chapter]

    public init(
        url: URL, title: String, subtitle: String? = nil, resolutions: [String] = [], subtitles: [SubtitleTrack] = [],
        chapters: [Chapter] = []
    ) {
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.resolutions = resolutions
        self.subtitles = subtitles
        self.chapters = chapters
    }
}

public enum PlayerQuality: Hashable, Sendable {
    case auto
    case maximum(height: Int)

    /// Highest first, with Auto at the top. Ignores labels that aren't of the form "720p".
    public static func options(from resolutions: [String]) -> [PlayerQuality] {
        let heights = Set(resolutions.compactMap { Int($0.lowercased().replacingOccurrences(of: "p", with: "")) })
        return [.auto] + heights.sorted(by: >).map { .maximum(height: $0) }
    }

    var preferredMaximumResolution: CGSize {
        switch self {
        case .auto: .zero
        case .maximum(let height): CGSize(width: (Double(height) * 16 / 9).rounded(.up), height: Double(height))
        }
    }
}

public enum PlayerPhase: Hashable, Sendable {
    case idle, loading, ready, failed
}

/// Platform-neutral control over one AVPlayer. Surfaces render it; features only talk to this.
@MainActor @Observable
public final class PlayerController {
    public static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    public static let skipInterval: Double = 10

    public let player = AVPlayer()
    public private(set) var item: PlaybackItem?
    public private(set) var phase: PlayerPhase = .idle
    public private(set) var isPlaying = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var quality: PlayerQuality = .auto
    public private(set) var speed: Float = 1
    public private(set) var selectedSubtitleID: String?
    public private(set) var currentCue: SubtitleCue?

    public var qualityOptions: [PlayerQuality] { PlayerQuality.options(from: item?.resolutions ?? []) }
    public var currentChapter: Chapter? { item?.chapters.last { $0.startTime <= currentTime } }

    private let subtitleLoader: @Sendable (URL) async throws -> String
    @ObservationIgnored private var cueTimeline = CueTimeline([])
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    #if os(iOS) || os(macOS)
        @ObservationIgnored private lazy var nowPlaying = NowPlayingCoordinator(controller: self)
    #endif

    public init(subtitleLoader: @escaping @Sendable (URL) async throws -> String) {
        self.subtitleLoader = subtitleLoader
    }

    public func load(_ newItem: PlaybackItem, autoplay: Bool = true) {
        teardownObservers()
        item = newItem
        phase = .loading
        quality = .auto
        selectedSubtitleID = nil
        currentCue = nil
        cueTimeline = CueTimeline([])
        currentTime = 0
        duration = 0

        let playerItem = AVPlayerItem(url: newItem.url)
        playerItem.audioTimePitchAlgorithm = .timeDomain
        player.defaultRate = speed
        player.replaceCurrentItem(with: playerItem)
        observe(playerItem)
        configureAudioSession()
        #if os(iOS) || os(macOS)
            nowPlaying.activate()
        #endif
        if autoplay { play() }
    }

    public func play() { player.playImmediately(atRate: speed) }
    public func pause() { player.pause() }

    public func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    public func seek(to seconds: Double) {
        let upper = duration > 0 ? duration : seconds
        let target = min(max(0, seconds), upper)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        applyTime(target)
    }

    public func skip(by delta: Double) { seek(to: currentTime + delta) }

    public func setQuality(_ newQuality: PlayerQuality) {
        quality = newQuality
        player.currentItem?.preferredMaximumResolution = newQuality.preferredMaximumResolution
    }

    public func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        player.defaultRate = newSpeed
        if isPlaying { player.rate = newSpeed }
    }

    public func selectSubtitle(id: String?) {
        subtitleTask?.cancel()
        selectedSubtitleID = id
        cueTimeline = CueTimeline([])
        currentCue = nil
        guard let id, let track = item?.subtitles.first(where: { $0.id == id }) else { return }
        let loader = subtitleLoader
        subtitleTask = Task { [weak self] in
            do {
                let text = try await loader(track.url)
                guard !Task.isCancelled, let self, self.selectedSubtitleID == id else { return }
                self.cueTimeline = CueTimeline(WebVTT.parse(text))
                self.currentCue = self.cueTimeline.cue(at: self.currentTime)
            } catch {
                AUNLog.player.error("Subtitle load failed: \(error)")
            }
        }
    }

    /// Stops playback and releases observers. Call when the watch screen goes away.
    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        teardownObservers()
        phase = .idle
        item = nil
        isPlaying = false
        #if os(iOS) || os(macOS)
            nowPlaying.deactivate()
        #endif
    }

    private func observe(_ playerItem: AVPlayerItem) {
        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.handle(status: status, error: playerItem.error) }
            }
            .store(in: &cancellables)
        playerItem.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    if value.isNumeric { self?.duration = value.seconds }
                }
            }
            .store(in: &cancellables)
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.handle(timeControl: status) }
            }
            .store(in: &cancellables)
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.applyTime(time.seconds) }
        }
    }

    private func handle(status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            phase = .ready
        case .failed:
            phase = .failed
            AUNLog.player.error("Playback failed: \(String(describing: error))")
        default:
            break
        }
    }

    private func handle(timeControl status: AVPlayer.TimeControlStatus) {
        isPlaying = status != .paused
        #if os(iOS) || os(macOS)
            nowPlaying.update()
        #endif
    }

    private func applyTime(_ time: Double) {
        guard time.isFinite else { return }
        currentTime = time
        let cue = cueTimeline.cue(at: time)
        if cue != currentCue { currentCue = cue }
    }

    private func teardownObservers() {
        cancellables.removeAll()
        subtitleTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func configureAudioSession() {
        #if os(iOS) || os(tvOS)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } catch {
                AUNLog.player.error("Audio session failed: \(error)")
            }
        #endif
    }
}

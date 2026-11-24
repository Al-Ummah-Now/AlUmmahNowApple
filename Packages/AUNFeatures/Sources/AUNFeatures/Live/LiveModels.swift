import AUNCoreBridge
import AUNPlayer
import Foundation
import Observation

/// What is on air and what is coming. Nothing on the screen while there is none.
@MainActor @Observable
public final class LiveListModel {
    public private(set) var onAir: [LiveStream] = []
    public private(set) var coming: [LiveStream] = []
    public private(set) var state: LoadState<Bool> = .loading
    /// The event filter is offered (the `liveEvents` switch).
    public private(set) var hasEvents = false
    public private(set) var event: LiveEventType?
    private let live: any LiveServicing
    private let now: @Sendable () -> Date

    public init(live: any LiveServicing, now: @escaping @Sendable () -> Date = { Date() }) {
        self.live = live
        self.now = now
    }

    public var isEmpty: Bool { onAir.isEmpty && coming.isEmpty }

    public func load() async {
        let features = await live.features()
        hasEvents = features.isOn(.liveEvents)
        if !hasEvents { event = nil }
        // The coming list is Epic 17's: premieres, reminders and event tags
        let hasComing = [.livePremieres, .liveReminders, .liveEvents].contains(where: features.isOn)
        do {
            async let onAirNow = live.streams(.live, event: event)
            async let scheduled = hasComing ? live.streams(.scheduled, event: event) : []
            let (current, next) = try await (onAirNow, scheduled)
            let moment = now()
            onAir = current
            coming = next.filter { ($0.scheduledStart ?? .distantPast) > moment }
                .sorted { ($0.scheduledStart ?? .distantFuture) < ($1.scheduledStart ?? .distantFuture) }
            state = .loaded(true)
        } catch is CancellationError {
            return
        } catch {
            AUNLog.network.error("Live list failed: \(error)")
            if case .loaded = state { return }
            state = .failed
        }
    }

    public func choose(_ event: LiveEventType?) async {
        self.event = event
        await load()
    }
}

public enum LiveMode: String, Sendable {
    case live, recording, soon, ended, cancelled

    init(_ state: LiveState) {
        if state.status == .cancelled {
            self = .cancelled
        } else if state.kind == .premiere {
            switch state.status {
            case .live: self = state.premiereVideoID == nil ? .soon : .live
            case .ended: self = state.premiereVideoID == nil ? .ended : .recording
            default: self = .soon
            }
        } else if state.status == .ended || state.sessionStatus == "ended" {
            self = state.vodURL == nil ? .ended : .recording
        } else if state.status == .live || state.sessionStatus == "live", state.playbackURL != nil {
            self = .live
        } else {
            self = .soon
        }
    }
}

public struct LiveContent: Sendable {
    public var stream: LiveStream
    public var timed: TimedLiveState
    public var mode: LiveMode
}

/// One live stream or premiere: the countdown, the stream, its recording, and the chat beside it.
@MainActor @Observable
public final class LiveWatchModel {
    public private(set) var state: LoadState<LiveContent> = .loading
    public private(set) var messages: [LiveChatMessage] = []
    public private(set) var pinned: LiveChatMessage?
    public private(set) var viewers: Int?
    /// The viewer went back or paused; the stream or premiere goes on without them.
    public private(set) var isBehind = false
    /// Seconds to a premiere's start, nil when it has no countdown.
    public private(set) var untilStart: Double?
    public let player: PlayerController

    private let streamID: String
    private let live: any LiveServicing
    private let catalog: any CatalogServicing
    private let now: @Sendable () -> Date
    private let viewerID = UUID().uuidString.lowercased()
    private var follower = PremiereFollower()
    private var premiere: PremiereClock?
    private var language = AppLanguage.en
    private var loadedURL: URL?
    private var premiereIsGone = false
    private var chatAt = Date.distantPast
    private var stateAt = Date.distantPast
    private var beatAt = Date.distantPast
    private var replay: [Int: [LiveChatMessage]] = [:]
    private var isReadingReplay = false

    nonisolated static let replayWindowMs = 60_000
    nonisolated static let shownMessages = 100
    nonisolated static let replayPages = 5
    /// Behind the newest moment of a stream by more than this is behind (a stream's delay is not).
    nonisolated static let behindLiveSeconds = 30.0

    public init(
        streamID: String, live: any LiveServicing, catalog: any CatalogServicing,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.streamID = streamID
        self.live = live
        self.catalog = catalog
        self.now = now
        player = PlayerController(subtitleLoader: { url in try await catalog.subtitleText(url: url) })
    }

    private var content: LiveContent? {
        if case .loaded(let content) = state { return content }
        return nil
    }

    public func load(language: AppLanguage) async {
        self.language = language
        state = .loading
        do {
            async let stream = live.stream(id: streamID)
            async let timed = live.state(id: streamID)
            await show(try await stream, try await timed)
        } catch is CancellationError {
            return
        } catch {
            AUNLog.network.error("Live watch failed: \(error)")
            state = .failed
        }
    }

    /// Runs while the screen is there.
    public func run() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: .seconds(1))
        }
        if content?.mode == .live { _ = await live.beat(id: streamID, viewerID: viewerID, leaving: true) }
    }

    public func returnToLive() {
        isBehind = false
        guard let premiere else { return player.returnToLive() }
        follower.returned()
        player.seek(to: premiere.position(at: now()))
        player.play()
    }

    /// One second: the clock, the player and whatever is due.
    func tick() async {
        guard let content else { return }
        updateCountdown(content)
        follow(content)
        let moment = now()
        if moment.timeIntervalSince(stateAt) >= stateInterval(content) { await refreshState(content.stream) }
        guard let content = self.content else { return }
        await refreshChat(content, at: moment)
        if content.mode == .live, moment.timeIntervalSince(beatAt) >= 20 {
            beatAt = moment
            viewers = await live.beat(id: streamID, viewerID: viewerID, leaving: false) ?? viewers
        }
    }

    private func stateInterval(_ content: LiveContent) -> TimeInterval {
        switch content.mode {
        case .live: 60
        // A premiere's time has come: it starts within the minute
        case .soon: (untilStart ?? 1) <= 0 ? 5 : 15
        case .ended: premiereIsGone ? .infinity : 15
        case .recording, .cancelled: .infinity
        }
    }

    private func refreshState(_ stream: LiveStream) async {
        stateAt = now()
        guard let timed = try? await live.state(id: streamID) else { return }
        await show(stream, timed)
    }

    private func show(_ stream: LiveStream, _ timed: TimedLiveState) async {
        stateAt = now()
        var mode = LiveMode(timed.state)
        if premiereIsGone, mode == .recording { mode = .ended }
        if timed.state.chat.enabled == false, mode != .recording { (messages, pinned) = ([], nil) }
        if let count = timed.state.viewers { viewers = count }
        let content = LiveContent(stream: stream, timed: timed, mode: mode)
        state = .loaded(content)
        updateCountdown(content)
        await play(content)
    }

    private func updateCountdown(_ content: LiveContent) {
        let state = content.timed.state
        guard content.mode == .soon, state.kind == .premiere, let start = state.scheduledStart ?? content.stream.scheduledStart
        else { return untilStart = nil }
        untilStart = start.timeIntervalSince(now()) - content.timed.clockOffset
    }

    private func play(_ content: LiveContent) async {
        let state = content.timed.state
        if state.kind == .premiere {
            let startedAt = content.mode == .live ? state.startedAt : nil
            premiere = startedAt.map {
                PremiereClock(startedAt: $0, offset: content.timed.clockOffset, duration: state.durationSeconds)
            }
            if premiere == nil { isBehind = false }
            if content.mode == .live || content.mode == .recording, let id = state.premiereVideoID, loadedURL == nil {
                await loadPremiere(id, content)
            }
            return
        }
        switch content.mode {
        case .live: start(state.playbackURL, content)
        case .recording: start(state.vodURL, content)
        case .soon, .ended, .cancelled: break
        }
    }

    private func start(_ url: URL?, _ content: LiveContent, startAt: Double? = nil) {
        guard let url, url != loadedURL else { return }
        loadedURL = url
        player.load(PlaybackItem(url: url, title: content.stream.title, subtitle: content.stream.channelName, startAt: startAt))
    }

    /// The video is released a moment after the premiere starts: asked for again at the next tick until it is there.
    private func loadPremiere(_ id: String, _ content: LiveContent) async {
        if let video = try? await catalog.video(id: id), video.isPlayable, let url = video.playURL {
            start(url, content, startAt: premiere?.position(at: now()))
        } else if content.mode == .recording {
            premiereIsGone = true
            state = .loaded(LiveContent(stream: content.stream, timed: content.timed, mode: .ended))
        } else {
            // Not yet: the state is read again in 5 seconds, and this with it
            stateAt = now().addingTimeInterval(-55)
        }
    }

    private func follow(_ content: LiveContent) {
        guard content.mode == .live else { return isBehind = false }
        guard content.timed.state.kind == .premiere else {
            isBehind = (player.secondsBehindLive ?? 0) > Self.behindLiveSeconds
            return
        }
        guard let premiere, player.phase == .ready, !premiere.isOver(at: now()) else { return isBehind = false }
        let reading = PremiereFollower.Reading(
            moment: premiere.position(at: now()), time: player.currentTime, isPlaying: player.isPlaying,
            canKeepUp: player.canKeepUp, speed: player.speed)
        for action in follower.tick(reading) {
            switch action {
            case .seek(let time): player.seek(to: time)
            case .normalSpeed: player.setSpeed(1)
            }
        }
        isBehind = follower.isBehind
    }

    private func refreshChat(_ content: LiveContent, at moment: Date) async {
        let chat = content.timed.state.chat
        switch content.mode {
        case .live where chat.enabled, .soon where chat.enabled:
            guard moment.timeIntervalSince(chatAt) >= (content.mode == .live ? 10 : 30) else { return }
            chatAt = moment
            guard let page = try? await live.chat(id: streamID) else { return }
            (messages, pinned) = (page.messages, page.pinned)
        case .recording where chat.replay:
            await refreshReplay()
        default: break
        }
    }

    /// What had been written by the moment being watched, read in windows as playback reaches them.
    private func refreshReplay() async {
        let time = Int(player.currentTime * 1000)
        let window = time / Self.replayWindowMs
        if !isReadingReplay {
            isReadingReplay = true
            // The one before, so a seek does not open an empty chat, and the next, so it is there in time
            for n in [window, window + 1, window - 1] where n >= 0 && replay[n] == nil { replay[n] = await readWindow(n) }
            isReadingReplay = false
        }
        var shown: [LiveChatMessage] = []
        var n = window
        while let list = replay[n], shown.count < Self.shownMessages {
            shown = list.filter { $0.offsetMs <= time } + shown
            n -= 1
        }
        messages = Array(shown.suffix(Self.shownMessages))
    }

    /// nil when it could not be read; asked for again at the next tick.
    private func readWindow(_ n: Int) async -> [LiveChatMessage]? {
        var from = n * Self.replayWindowMs
        let to = from + Self.replayWindowMs
        var all: [String: LiveChatMessage] = [:]
        for _ in 0..<Self.replayPages {
            guard let page = try? await live.chatReplay(id: streamID, fromMs: from, toMs: to) else { return nil }
            for message in page.messages where message.offsetMs < to { all[message.id] = message }
            guard page.truncated == true, let last = page.messages.last, last.offsetMs > from else { break }
            from = last.offsetMs
        }
        return all.values.sorted { ($0.offsetMs, $0.id) < ($1.offsetMs, $1.id) }
    }
}

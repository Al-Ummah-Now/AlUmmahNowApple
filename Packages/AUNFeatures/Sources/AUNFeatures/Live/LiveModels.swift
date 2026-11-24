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
    private var chatDue = Date.distantPast
    private var stateAt = Date.distantPast
    /// The server's own wait for the state, over this app's.
    private var stateWait: TimeInterval?
    private var beatDue = Date.distantPast
    private var replay: [Int: [LiveChatMessage]] = [:]
    private var isReadingReplay = false

    nonisolated static let replayWindowMs = 60_000
    nonisolated static let shownMessages = 100
    nonisolated static let replayPages = 5
    /// After a read of the chat that failed.
    nonisolated static let chatBackoff: TimeInterval = 60
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
            let read = try await timed
            stateWait = Self.pollAfter(read.state.pollAfter)
            await show(try await stream, read)
        } catch is CancellationError {
            return
        } catch {
            AUNLog.network.error("Live watch failed: \(error)")
            state = .failed
        }
    }

    /// Runs while the screen is there and the app is not in the background.
    public func run() async {
        // The clock and the player do not wait for the network
        let clock = Task {
            while !Task.isCancelled {
                step()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: .seconds(1))
        }
        clock.cancel()
        guard content?.mode == .live else { return }
        // This task is cancelled, and a request in it would be too: counted out in one of its own
        beatDue = .distantPast
        Task.detached { [live, streamID, viewerID] in
            _ = try? await live.beat(id: streamID, viewerID: viewerID, leaving: true)
        }
    }

    /// When the server wants to be asked again, so it can slow installed apps down. Between 5 seconds and 10 minutes whatever
    /// it says: a bad value neither stops the app nor makes it hammer.
    nonisolated static func pollAfter(_ seconds: TimeInterval?) -> TimeInterval? {
        seconds.map { min(max($0, 5), 600) }
    }

    /// The read, or nil and when the server said to ask again, if it did. Throws only when the screen's task was cancelled:
    /// nothing was refused then, and nothing of what is due changes.
    private func asked<T>(_ read: () async throws -> T) async throws(CancellationError) -> (T?, TimeInterval?) {
        do {
            return (try await read(), nil)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return (nil, Self.pollAfter((error as? LiveRefused)?.retryAfter))
        }
    }

    public func returnToLive() {
        isBehind = false
        guard let premiere else { return player.returnToLive() }
        follower.returned()
        player.seek(to: premiere.position(at: now()))
        player.play()
    }

    /// One second of the clock and the player.
    func step() {
        guard let content else { return }
        updateCountdown(content)
        follow(content)
    }

    /// Whatever is due. Every wait begins when the answer is there, however long that took.
    func poll() async {
        // Cancelled on the way: asked for again when the screen is back
        try? await readWhatIsDue()
    }

    private func readWhatIsDue() async throws(CancellationError) {
        guard let content else { return }
        if now().timeIntervalSince(stateAt) >= stateInterval(content) { try await refreshState(content.stream) }
        guard let content = self.content else { return }
        try await refreshChat(content)
        if content.mode == .live, now() >= beatDue {
            let (count, wait) = try await asked { try await live.beat(id: streamID, viewerID: viewerID, leaving: false) }
            beatDue = now().addingTimeInterval(wait ?? 20)
            viewers = (count ?? nil) ?? viewers
        }
    }

    /// The server's wait when it gave one, else this app's; nothing is asked of what will not change.
    private func stateInterval(_ content: LiveContent) -> TimeInterval {
        let own = ownInterval(content)
        return own == .infinity ? own : stateWait ?? own
    }

    private func ownInterval(_ content: LiveContent) -> TimeInterval {
        switch content.mode {
        // A premiere's video is released a moment after it starts
        case .live: content.timed.state.kind == .premiere && loadedURL == nil ? 5 : 60
        // A premiere's time has come: it starts within the minute
        case .soon: (untilStart ?? 1) <= 0 ? 5 : 15
        case .ended: premiereIsGone ? .infinity : 15
        // A premiere's video that could not be read
        case .recording: content.timed.state.kind == .premiere && loadedURL == nil ? 15 : .infinity
        case .cancelled: .infinity
        }
    }

    private func refreshState(_ stream: LiveStream) async throws(CancellationError) {
        let (timed, wait) = try await asked { try await live.state(id: streamID) }
        stateAt = now()
        stateWait = timed.map { Self.pollAfter($0.state.pollAfter) } ?? wait
        if let timed { await show(stream, timed) }
    }

    private func show(_ stream: LiveStream, _ timed: TimedLiveState) async {
        stateAt = now()
        var mode = LiveMode(timed.state)
        if premiereIsGone, mode == .recording { mode = .ended }
        let hasChat = mode == .recording ? timed.state.chat.replay : timed.state.chat.enabled
        if !hasChat { (messages, pinned) = ([], nil) }
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

    /// The video is released a moment after the premiere starts: asked for again with the state until it is there.
    private func loadPremiere(_ id: String, _ content: LiveContent) async {
        let video: Video?
        do {
            video = try await catalog.video(id: id)
        } catch CoreError.notFound {
            video = nil
        } catch {
            // Not an answer: asked for again
            return
        }
        if let video, video.isPlayable, let url = video.playURL {
            start(url, content, startAt: premiere?.position(at: now()))
        } else if content.mode == .recording {
            premiereIsGone = true
            state = .loaded(LiveContent(stream: content.stream, timed: content.timed, mode: .ended))
        }
    }

    private func follow(_ content: LiveContent) {
        guard content.mode == .live else { return isBehind = false }
        guard content.timed.state.kind == .premiere else {
            isBehind = (player.secondsBehindLive ?? 0) > Self.behindLiveSeconds
            return
        }
        guard let premiere, player.phase == .ready, !premiere.isOver(at: now()) else { return isBehind = false }
        // Until a seek lands the player reports where it was
        guard !player.isSeeking else { return }
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

    private func refreshChat(_ content: LiveContent) async throws(CancellationError) {
        let chat = content.timed.state.chat
        switch content.mode {
        case .live where chat.enabled, .soon where chat.enabled:
            guard now() >= chatDue else { return }
            let (read, wait) = try await asked { try await live.chat(id: streamID) }
            guard let page = read else {
                chatDue = now().addingTimeInterval(wait ?? Self.chatBackoff)
                return
            }
            chatDue = now().addingTimeInterval(Self.pollAfter(page.pollAfter) ?? (content.mode == .live ? 10 : 30))
            (messages, pinned) = (page.messages, page.pinned)
        case .recording where chat.replay:
            try await refreshReplay()
        default: break
        }
    }

    /// What had been written by the moment being watched, read in windows as playback reaches them.
    private func refreshReplay() async throws(CancellationError) {
        let time = Int(player.currentTime * 1000)
        let window = time / Self.replayWindowMs
        if !isReadingReplay {
            isReadingReplay = true
            defer { isReadingReplay = false }
            // The one before, so a seek does not open an empty chat, and the next, so it is there in time
            for n in [window, window + 1, window - 1] where n >= 0 && replay[n] == nil && now() >= chatDue {
                let (list, wait) = try await readWindow(n)
                replay[n] = list
                if list == nil { chatDue = now().addingTimeInterval(wait ?? Self.chatBackoff) }
            }
        }
        var shown: [LiveChatMessage] = []
        var n = window
        while let list = replay[n], shown.count < Self.shownMessages {
            shown = list.filter { $0.offsetMs <= time } + shown
            n -= 1
        }
        messages = Array(shown.suffix(Self.shownMessages))
    }

    /// nil when it could not be read, and when the server said to ask again, if it did.
    private func readWindow(_ n: Int) async throws(CancellationError) -> ([LiveChatMessage]?, TimeInterval?) {
        var from = n * Self.replayWindowMs
        let to = from + Self.replayWindowMs
        var all: [String: LiveChatMessage] = [:]
        for _ in 0..<Self.replayPages {
            let (read, wait) = try await asked { try await live.chatReplay(id: streamID, fromMs: from, toMs: to) }
            guard let page = read else { return (nil, wait) }
            for message in page.messages where message.offsetMs < to { all[message.id] = message }
            guard page.truncated == true, let last = page.messages.last, last.offsetMs > from else { break }
            from = last.offsetMs
        }
        return (all.values.sorted { ($0.offsetMs, $0.id) < ($1.offsetMs, $1.id) }, nil)
    }
}

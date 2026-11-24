import AUNCoreBridge
import Foundation
import Testing

@testable import AUNFeatures

/// A clock the test moves.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private actor StubLive: LiveServicing {
    var current: LiveState
    var on: Set<UserFeature> = [.livePremieres, .liveEvents]
    var lists: [LiveStatus: [LiveStream]] = [:]
    var windows: [Int: LiveChatPage] = [:]
    private(set) var stateReads = 0
    private(set) var chatReads = 0
    private(set) var askedEvent: LiveEventType?
    let offset: TimeInterval

    init(_ state: LiveState = LiveState(status: .scheduled), offset: TimeInterval = 0) {
        current = state
        self.offset = offset
    }

    func set(_ state: LiveState) { current = state }
    func set(on: Set<UserFeature>) { self.on = on }
    func set(_ status: LiveStatus, _ streams: [LiveStream]) { lists[status] = streams }
    func set(window from: Int, _ page: LiveChatPage) { windows[from] = page }

    func features() async -> UserFeatures { UserFeatures(on: on) }
    func streams(_ status: LiveStatus, event: LiveEventType?) async throws -> [LiveStream] {
        askedEvent = event
        return lists[status] ?? []
    }
    func stream(id: String) async throws -> LiveStream { LiveStream(id: id, title: "T", status: current.status) }
    func state(id: String) async throws -> TimedLiveState {
        stateReads += 1
        return TimedLiveState(state: current, clockOffset: offset)
    }
    func chat(id: String) async throws -> LiveChatPage {
        chatReads += 1
        return LiveChatPage(messages: [LiveChatMessage(id: "m", authorName: "A", text: "x", offsetMs: 0)])
    }
    func chatReplay(id: String, fromMs: Int, toMs: Int) async throws -> LiveChatPage {
        windows[fromMs] ?? LiveChatPage(messages: [])
    }
    func beat(id: String, viewerID: String, leaving: Bool) async -> Int? { 5 }
}

@Suite struct PremiereClockTests {
    @Test func isTheServersTimeWithinTheVideo() {
        let start = Date(timeIntervalSince1970: 1000)
        let clock = PremiereClock(startedAt: start, offset: 20, duration: 600)
        #expect(clock.position(at: start.addingTimeInterval(90)) == 110)
        #expect(clock.position(at: start.addingTimeInterval(-60)) == 0)
        #expect(clock.position(at: start.addingTimeInterval(900)) == 600)
        #expect(clock.isOver(at: start.addingTimeInterval(580)))
        #expect(!clock.isOver(at: start.addingTimeInterval(579)))
    }
}

@Suite struct PremiereFollowerTests {
    private func reading(_ moment: Double, _ time: Double, playing: Bool = true, keepUp: Bool = true, speed: Float = 1)
        -> PremiereFollower.Reading
    { .init(moment: moment, time: time, isPlaying: playing, canKeepUp: keepUp, speed: speed) }

    @Test func comesBackWhenItDriftsButNotWhileLoading() {
        var follower = PremiereFollower()
        #expect(follower.tick(reading(100, 99)).isEmpty)
        #expect(follower.tick(reading(105, 99.5, keepUp: false)).isEmpty)
        #expect(follower.tick(reading(106, 100)) == [.seek(106)])
        #expect(!follower.isBehind)
    }

    @Test func nobodyGetsAheadOrFaster() {
        var follower = PremiereFollower()
        _ = follower.tick(reading(100, 100))
        #expect(follower.tick(reading(101, 300)) == [.seek(101)])
        #expect(follower.tick(reading(102, 102, speed: 2)) == [.normalSpeed])
    }

    @Test func aViewerWhoGoesBackStaysUntilTheyCatchUpOrReturn() {
        var follower = PremiereFollower()
        _ = follower.tick(reading(100, 100))
        #expect(follower.tick(reading(101, 40)).isEmpty)
        #expect(follower.isBehind)
        // Catching up may be faster
        #expect(follower.tick(reading(102, 42, speed: 2)).isEmpty)
        #expect(follower.tick(reading(103, 102.5, speed: 2)) == [.normalSpeed])
        #expect(!follower.isBehind)
        _ = follower.tick(reading(104, 50))
        #expect(follower.isBehind)
        follower.returned()
        #expect(follower.tick(reading(105, 50)) == [.seek(105)])
    }

    @Test func aPauseIsTheViewersButNotBeforeItHasPlayed() {
        var follower = PremiereFollower()
        _ = follower.tick(reading(100, 0, playing: false))
        #expect(follower.isFollowing)
        _ = follower.tick(reading(100, 100))
        _ = follower.tick(reading(101, 100.5, playing: false))
        _ = follower.tick(reading(110, 100.5, playing: false))
        #expect(follower.isBehind)
        #expect(follower.tick(reading(111, 101)).isEmpty)
    }
}

@MainActor @Suite struct LiveModelTests {
    private let clock = TestClock()

    private func model(_ live: StubLive) -> LiveWatchModel {
        let clock = clock
        return LiveWatchModel(streamID: "s", live: live, catalog: FixtureCatalogService(), now: { clock.now })
    }

    private func content(_ model: LiveWatchModel) throws -> LiveContent {
        guard case .loaded(let content) = model.state else { throw CoreError.notFound }
        return content
    }

    @Test func modes() {
        #expect(LiveMode(LiveState(status: .scheduled)) == .soon)
        #expect(LiveMode(LiveState(status: .live, playbackURL: URL(string: "https://x.test"))) == .live)
        #expect(LiveMode(LiveState(status: .live)) == .soon)
        #expect(LiveMode(LiveState(status: .ended)) == .ended)
        #expect(LiveMode(LiveState(status: .ended, vodURL: URL(string: "https://x.test"))) == .recording)
        #expect(LiveMode(LiveState(status: .cancelled)) == .cancelled)
        #expect(LiveMode(LiveState(status: .live, kind: .premiere, premiereVideoID: "v")) == .live)
        #expect(LiveMode(LiveState(status: .scheduled, kind: .premiere, premiereVideoID: "v")) == .soon)
        #expect(LiveMode(LiveState(status: .ended, kind: .premiere, premiereVideoID: "v")) == .recording)
        #expect(LiveMode(LiveState(status: .ended, kind: .premiere)) == .ended)
    }

    @Test func countsDownByTheServersClockAndAsksOftenWhenItIsDue() async throws {
        let live = StubLive(
            LiveState(status: .scheduled, kind: .premiere, scheduledStart: clock.now.addingTimeInterval(100)), offset: 10)
        let model = model(live)
        await model.load(language: .en)
        #expect(model.untilStart == 90)
        clock.advance(14)
        await model.tick()
        #expect(await live.stateReads == 1)
        clock.advance(77)
        await model.tick()
        #expect(await live.stateReads == 2)
        #expect((model.untilStart ?? 0) < 0)
        clock.advance(5)
        await model.tick()
        #expect(await live.stateReads == 3)
    }

    @Test func aPremiereStartsAtItsMomentAndGoesOnAfterIt() async throws {
        let start = clock.now.addingTimeInterval(-30)
        let live = StubLive(
            LiveState(status: .live, kind: .premiere, startedAt: start, premiereVideoID: "fixture-1", durationSeconds: 600))
        let model = model(live)
        await model.load(language: .en)
        #expect(try content(model).mode == .live)
        #expect(model.player.item?.startAt == 30)
        let item = model.player.item
        await live.set(LiveState(status: .ended, kind: .premiere, startedAt: start, premiereVideoID: "fixture-1"))
        clock.advance(61)
        await model.tick()
        #expect(try content(model).mode == .recording)
        // The same item: it does not start over
        #expect(model.player.item == item)
        model.player.stop()
    }

    @Test func aVideoThatIsGoneIsSaidToBe() async throws {
        let live = StubLive(LiveState(status: .ended, kind: .premiere, premiereVideoID: "nope"))
        let model = model(live)
        await model.load(language: .en)
        #expect(try content(model).mode == .ended)
    }

    @Test func aVideoNotYetReleasedIsAskedForAgain() async throws {
        let live = StubLive(LiveState(status: .live, kind: .premiere, startedAt: clock.now, premiereVideoID: "nope"))
        let model = model(live)
        await model.load(language: .en)
        await live.set(LiveState(status: .live, kind: .premiere, startedAt: clock.now, premiereVideoID: "fixture-1"))
        clock.advance(5)
        await model.tick()
        #expect(model.player.item != nil)
        model.player.stop()
    }

    @Test func chatIsReadOnlyWhileTheServerSaysSo() async throws {
        let url = URL(string: "https://x.test/p.m3u8")
        let live = StubLive(LiveState(status: .live, playbackURL: url))
        let model = model(live)
        await model.load(language: .en)
        await model.tick()
        #expect(await live.chatReads == 0)
        #expect(try content(model).hasChat == false)
        await live.set(LiveState(status: .live, playbackURL: url, chat: .init(enabled: true)))
        clock.advance(60)
        await model.tick()
        #expect(await live.chatReads == 1)
        #expect(model.messages.count == 1)
        await model.tick()
        #expect(await live.chatReads == 1)
        clock.advance(10)
        await model.tick()
        #expect(await live.chatReads == 2)
        // Turned off: gone from the screen at the next read of the state
        await live.set(LiveState(status: .live, playbackURL: url))
        clock.advance(60)
        await model.tick()
        #expect(model.messages.isEmpty)
        model.player.stop()
    }

    @Test func theReplayIsWhatHadBeenWrittenByThen() async throws {
        let live = StubLive(LiveState(status: .ended, vodURL: URL(string: "https://x.test/v.m3u8"), chat: .init(replay: true)))
        await live.set(
            window: 0,
            LiveChatPage(messages: [
                LiveChatMessage(id: "a", authorName: "A", text: "x", offsetMs: 0),
                LiveChatMessage(id: "b", authorName: "A", text: "y", offsetMs: 5000),
            ]))
        let model = model(live)
        await model.load(language: .en)
        await model.tick()
        #expect(model.messages.map(\.id) == ["a"])
        model.player.stop()
    }

    @Test func theListShowsWhatComesNextAndOnlyWithItsSwitches() async {
        let live = StubLive()
        let now = clock.now
        await live.set(.live, [LiveStream(id: "on", title: "", status: .live)])
        await live.set(
            .scheduled,
            [
                LiveStream(id: "later", title: "", status: .scheduled, scheduledStart: now.addingTimeInterval(900)),
                LiveStream(id: "past", title: "", status: .scheduled, scheduledStart: now.addingTimeInterval(-1)),
                LiveStream(id: "untimed", title: "", status: .scheduled),
                LiveStream(id: "next", title: "", status: .scheduled, scheduledStart: now.addingTimeInterval(60)),
            ])
        let clock = clock
        let model = LiveListModel(live: live, now: { clock.now })
        await model.load()
        #expect(model.coming.map(\.id) == ["next", "later"])
        #expect(model.hasEvents)
        await model.choose(.jumuah)
        #expect(await live.askedEvent == .jumuah)
        await live.set(on: [])
        await model.load()
        #expect(model.onAir.map(\.id) == ["on"])
        #expect(model.coming.isEmpty)
        #expect(!model.hasEvents)
        #expect(model.event == nil)
    }
}

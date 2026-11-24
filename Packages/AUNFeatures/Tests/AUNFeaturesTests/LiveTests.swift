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
    private(set) var leaves = 0
    var chatFails = false
    var chatPollAfter: TimeInterval?
    var pinned: LiveChatMessage?
    /// One event's list is held back until `release`.
    var heldEvent: LiveEventType?
    private var held: CheckedContinuation<Void, Never>?
    var isHeld: Bool { held != nil }
    /// The beats in the order they were sent, and whether each is held back until `releaseBeat`.
    private(set) var sent: [Bool] = []
    private var holdsBeats = false
    private var heldBeat: CheckedContinuation<Void, Never>?
    var isBeatHeld: Bool { heldBeat != nil }
    func set(holdsBeats: Bool) { self.holdsBeats = holdsBeats }
    func releaseBeat() {
        heldBeat?.resume()
        heldBeat = nil
    }
    private(set) var windowReads: [Int] = []
    func release() {
        held?.resume()
        held = nil
    }
    func set(pinned: LiveChatMessage?) { self.pinned = pinned }
    func set(heldEvent: LiveEventType?) { self.heldEvent = heldEvent }
    /// Every read is refused with this `Retry-After`.
    var retryAfter: TimeInterval?
    /// The state does not answer.
    var isSlow = false
    private(set) var beats = 0
    let offset: TimeInterval

    init(_ state: LiveState = LiveState(status: .scheduled), offset: TimeInterval = 0) {
        current = state
        self.offset = offset
    }

    func set(_ state: LiveState) { current = state }
    func set(on: Set<UserFeature>) { self.on = on }
    func set(chatFails: Bool) { self.chatFails = chatFails }
    func set(chatPollAfter: TimeInterval?) { self.chatPollAfter = chatPollAfter }
    func set(retryAfter: TimeInterval?) { self.retryAfter = retryAfter }
    func set(isSlow: Bool) { self.isSlow = isSlow }
    /// Each answer takes this long on the test's clock.
    var takes: (@Sendable () -> Void)?
    func set(takes: (@Sendable () -> Void)?) { self.takes = takes }
    private func answerTakes() { takes?() }
    private func refuse() throws {
        if let retryAfter { throw LiveRefused(retryAfter: retryAfter) }
    }
    func set(_ status: LiveStatus, _ streams: [LiveStream]) { lists[status] = streams }
    func set(window from: Int, _ page: LiveChatPage) { windows[from] = page }

    func features() async -> UserFeatures { UserFeatures(on: on) }
    func streams(_ status: LiveStatus, event: LiveEventType?) async throws -> [LiveStream] {
        askedEvent = event
        if status == .live, let heldEvent, event == heldEvent { await withCheckedContinuation { held = $0 } }
        return lists[status] ?? []
    }
    func stream(id: String) async throws -> LiveStream { LiveStream(id: id, title: "T", status: current.status) }
    func state(id: String) async throws -> TimedLiveState {
        stateReads += 1
        answerTakes()
        if isSlow { try await Task.sleep(for: .seconds(60)) }
        try refuse()
        return TimedLiveState(state: current, clockOffset: offset)
    }
    func chat(id: String) async throws -> LiveChatPage {
        chatReads += 1
        answerTakes()
        if isSlow { try await Task.sleep(for: .seconds(60)) }
        try refuse()
        if chatFails { throw CoreError.http(status: 503) }
        return LiveChatPage(
            messages: [LiveChatMessage(id: "m", authorName: "A", text: "x", offsetMs: 0)], pinned: pinned,
            pollAfter: chatPollAfter)
    }
    func chatReplay(id: String, fromMs: Int, toMs: Int) async throws -> LiveChatPage {
        windowReads.append(fromMs)
        return windows[fromMs] ?? LiveChatPage(messages: [])
    }
    func beat(id: String, viewerID: String, leaving: Bool) async throws -> Int? {
        // As URLSession: nothing is sent in a cancelled task
        sent.append(leaving)
        if holdsBeats { await withCheckedContinuation { heldBeat = $0 } }
        if leaving, !Task.isCancelled { leaves += 1 }
        if !leaving { beats += 1 }
        if !leaving { answerTakes() }
        try refuse()
        return 5
    }
}

/// A catalog that answers with an error.
private struct BrokenCatalog: CatalogServicing {
    let error: CoreError
    func homeRails(limit: Int) async throws -> [HomeRail] { throw error }
    func video(id: String) async throws -> Video { throw error }
    func subtitles(videoID: String) async throws -> [SubtitleTrack] { throw error }
    func chapters(videoID: String) async throws -> [Chapter] { throw error }
    func subtitleText(url: URL) async throws -> String { throw error }
}

extension LiveWatchModel {
    /// One second.
    fileprivate func tick() async {
        step()
        await poll()
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

    @Test func leavingIsCountedThoughTheScreensTaskIsCancelled() async throws {
        let live = StubLive(LiveState(status: .live, playbackURL: URL(string: "https://x.test/p.m3u8")))
        let model = model(live)
        await model.load(language: .en)
        let run = Task { await model.run() }
        try await Task.sleep(for: .milliseconds(50))
        run.cancel()
        await run.value
        for _ in 0..<100 {
            if await live.leaves > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await live.leaves == 1)
        model.player.stop()
    }

    private func until(_ done: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await done())
    }

    @Test func aBeatOnItsWayWhenTheAppGoesToTheBackgroundCannotComeAfterTheLeave() async throws {
        let live = StubLive(LiveState(status: .live, playbackURL: URL(string: "https://x.test/p.m3u8")))
        let model = model(live)
        await model.load(language: .en)
        await live.set(holdsBeats: true)
        let run = Task { await model.run() }
        try await until { await live.isBeatHeld }
        run.cancel()
        try await Task.sleep(for: .milliseconds(50))
        // The leave is not sent before the beat is answered
        #expect(await live.sent == [false])
        await live.set(holdsBeats: false)
        await live.releaseBeat()
        try await until { await live.sent == [false, true] }
        await run.value
        #expect(await live.sent == [false, true])
        model.player.stop()
    }

    @Test func aLeaveOnItsWayWhenTheViewerComesBackCannotComeAfterTheBeat() async throws {
        let live = StubLive(LiveState(status: .live, playbackURL: URL(string: "https://x.test/p.m3u8")))
        let model = model(live)
        await model.load(language: .en)
        let first = Task { await model.run() }
        try await until { await live.beats == 1 }
        await live.set(holdsBeats: true)
        first.cancel()
        try await until { await live.isBeatHeld }
        let second = Task { await model.run() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await live.sent == [false, true])
        await live.set(holdsBeats: false)
        await live.releaseBeat()
        try await until { await live.sent == [false, true, false] }
        second.cancel()
        await second.value
        model.player.stop()
    }

    @Test func aChatThatCannotBeReadIsAskedForOnceAMinute() async throws {
        let live = StubLive(
            LiveState(status: .live, playbackURL: URL(string: "https://x.test/p.m3u8"), chat: .init(enabled: true)))
        await live.set(chatFails: true)
        let model = model(live)
        await model.load(language: .en)
        await model.tick()
        clock.advance(59)
        await model.tick()
        #expect(await live.chatReads == 1)
        clock.advance(1)
        await model.tick()
        #expect(await live.chatReads == 2)
        model.player.stop()
    }

    @Test func theServerSaysWhenToAskAgain() async throws {
        let url = URL(string: "https://x.test/p.m3u8")
        let live = StubLive(LiveState(status: .live, playbackURL: url, chat: .init(enabled: true), pollAfter: 120))
        await live.set(chatPollAfter: 30)
        let model = model(live)
        await model.load(language: .en)
        await model.tick()
        clock.advance(29)
        await model.tick()
        #expect(await live.chatReads == 1)
        clock.advance(1)
        await model.tick()
        #expect(await live.chatReads == 2)
        clock.advance(89)
        await model.tick()
        #expect(await live.stateReads == 1)
        clock.advance(1)
        await live.set(LiveState(status: .live, playbackURL: url, chat: .init(enabled: true)))
        await model.tick()
        #expect(await live.stateReads == 2)
        // It says nothing any more: this app's interval again
        clock.advance(60)
        await model.tick()
        #expect(await live.stateReads == 3)
        model.player.stop()
    }

    @Test func aRefusalSaysWhenToAskAgain() async throws {
        let live = StubLive(
            LiveState(status: .live, playbackURL: URL(string: "https://x.test/p.m3u8"), chat: .init(enabled: true)))
        let model = model(live)
        await model.load(language: .en)
        await live.set(retryAfter: 200)
        await model.tick()
        clock.advance(60)
        await model.tick()
        let asked = [await live.stateReads, await live.chatReads, await live.beats]
        clock.advance(139)
        await model.tick()
        #expect([await live.stateReads, await live.chatReads, await live.beats] == asked)
        clock.advance(61)
        await model.tick()
        #expect([await live.stateReads, await live.chatReads, await live.beats] == asked.map { $0 + 1 })
        model.player.stop()
    }

    @Test func aWaitBeginsWhenTheAnswerIsThere() async throws {
        let url = URL(string: "https://x.test/p.m3u8")
        let live = StubLive(LiveState(status: .live, playbackURL: url, chat: .init(enabled: true)))
        let model = model(live)
        await model.load(language: .en)
        let clock = clock
        await live.set(takes: { clock.advance(8) })
        await model.tick()  // The chat and the beat are read
        clock.advance(60)
        await model.tick()  // So is the state: 8 s each
        let asked = [await live.stateReads, await live.chatReads, await live.beats]
        await live.set(takes: nil)
        // The chat's 10 seconds are not over: they began when its answer came, 8 s before the beat's
        clock.advance(1)
        await model.tick()
        #expect(await live.chatReads == asked[1])
        clock.advance(1)
        await model.tick()
        #expect(await live.chatReads == asked[1] + 1)
        // Nor the beat's 20
        clock.advance(17)
        await model.tick()
        #expect(await live.beats == asked[2])
        clock.advance(1)
        await model.tick()
        #expect(await live.beats == asked[2] + 1)
        // The state's 60 began 16 s before the beat's
        clock.advance(23)
        await model.tick()
        #expect(await live.stateReads == asked[0])
        clock.advance(1)
        await model.tick()
        #expect(await live.stateReads == asked[0] + 1)
        model.player.stop()
    }

    @Test func goingToTheBackgroundIsNotAFailure() async throws {
        let url = URL(string: "https://x.test/p.m3u8")
        let live = StubLive(LiveState(status: .live, playbackURL: url, chat: .init(enabled: true), pollAfter: 120))
        let model = model(live)
        await model.load(language: .en)
        // The chat's answer is on its way
        await live.set(isSlow: true)
        func cancelled(_ isOnItsWay: @escaping () async -> Bool) async throws {
            let run = Task { await model.run() }
            for _ in 0..<200 {
                if await isOnItsWay() { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            run.cancel()
            await run.value
        }
        try await cancelled { await live.chatReads == 1 }
        await live.set(isSlow: false)
        await model.tick()
        // Asked at once, not after a failure's minute
        #expect(await live.chatReads == 2)
        // And the state's
        clock.advance(120)
        await live.set(isSlow: true)
        try await cancelled { await live.stateReads == 2 }
        await live.set(isSlow: false)
        await model.tick()
        #expect(await live.stateReads == 3)
        model.player.stop()
    }

    @Test func aPremieresVideoThatCouldNotBeReadIsAskedForAgain() async throws {
        let live = StubLive(LiveState(status: .ended, kind: .premiere, premiereVideoID: "v", durationSeconds: 600))
        let clock = clock
        let failing = LiveWatchModel(streamID: "s", live: live, catalog: BrokenCatalog(error: .offline), now: { clock.now })
        await failing.load(language: .en)
        #expect(try content(failing).mode == .recording)
        clock.advance(15)
        await failing.poll()
        #expect(await live.stateReads == 2)
        let gone = LiveWatchModel(streamID: "s", live: live, catalog: BrokenCatalog(error: .notFound), now: { clock.now })
        await gone.load(language: .en)
        #expect(try content(gone).mode == .ended)
    }

    @Test func whatTheServerSaysIsKeptBetween5SecondsAnd10Minutes() {
        #expect(LiveWatchModel.pollAfter(nil) == nil)
        #expect([-1, 0, 7, .greatestFiniteMagnitude].map { LiveWatchModel.pollAfter($0) } == [5, 5, 7, 600])
    }

    @Test func theClockDoesNotWaitForTheNetwork() async throws {
        let start = clock.now.addingTimeInterval(100)
        let live = StubLive(LiveState(status: .scheduled, kind: .premiere, scheduledStart: start))
        let model = model(live)
        await model.load(language: .en)
        await live.set(isSlow: true)
        clock.advance(20)
        let run = Task { await model.run() }
        for _ in 0..<100 {
            if await live.stateReads == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        clock.advance(30)
        for _ in 0..<300 {
            if model.untilStart == 50 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.untilStart == 50)
        run.cancel()
        await run.value
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

    @Test func anEarlierChoiceThatAnswersLateIsNotShown() async throws {
        let live = StubLive()
        await live.set(heldEvent: .jumuah)
        await live.set(.live, [LiveStream(id: "on", title: "", status: .live)])
        let clock = clock
        let model = LiveListModel(live: live, now: { clock.now })
        let late = Task { await model.choose(.jumuah) }
        for _ in 0..<100 {
            if await live.isHeld { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.choose(.halqa)
        await live.set(.live, [LiveStream(id: "late", title: "", status: .live)])
        await live.release()
        await late.value
        #expect(model.event == .halqa)
        #expect(model.onAir.map(\.id) == ["on"])
    }

    @Test func theReplayBeginsWithoutWhatWasLiveAndAtItsOwnTime() async throws {
        let live = StubLive(
            LiveState(status: .live, playbackURL: URL(string: "https://x.test/p.m3u8"), chat: .init(enabled: true)))
        await live.set(pinned: LiveChatMessage(id: "p", authorName: "A", text: "x", offsetMs: 0))
        let model = model(live)
        await model.load(language: .en)
        await model.tick()
        #expect(model.pinned?.id == "p")
        clock.advance(59)
        // A live chat that could not be read waits a minute; the replay does not
        await live.set(chatFails: true)
        await model.tick()
        clock.advance(1)
        await live.set(LiveState(status: .ended, vodURL: URL(string: "https://x.test/v.m3u8"), chat: .init(replay: true)))
        await live.set(
            window: 0, LiveChatPage(messages: [LiveChatMessage(id: "a", authorName: "A", text: "x", offsetMs: 0)]))
        await model.tick()
        #expect(try content(model).mode == .recording)
        #expect(model.pinned == nil)
        #expect(model.messages.map(\.id) == ["a"])
        model.player.stop()
    }

    @Test func theReplayFollowsTheServersPace() async throws {
        let live = StubLive(LiveState(status: .ended, vodURL: URL(string: "https://x.test/v.m3u8"), chat: .init(replay: true)))
        await live.set(window: 0, LiveChatPage(messages: [], pollAfter: 30))
        let model = model(live)
        await model.load(language: .en)
        await model.tick()
        clock.advance(29)
        await model.tick()
        #expect(await live.windowReads == [0])
        clock.advance(1)
        await model.tick()
        #expect(await live.windowReads == [0, 60_000])
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

import AUNCoreBridge
import Foundation
import Testing

@testable import AUNFeatures

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
            model.setActive(true)
            try await until(isOnItsWay)
            model.setActive(false)
            await model.settled()
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
        model.setActive(true)
        try await until { await live.stateReads == 2 }
        clock.advance(30)
        for _ in 0..<300 {
            if model.untilStart == 50 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.untilStart == 50)
        model.setActive(false)
        await model.settled()
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

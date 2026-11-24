import AUNCoreBridge
import Foundation
import Testing

@testable import AUNFeatures

/// Counting the viewer in and out, and what runs while the screen is there.
@MainActor @Suite struct LivePresenceTests {
    private let clock = TestClock()

    private func model(_ live: StubLive) -> LiveWatchModel {
        let clock = clock
        return LiveWatchModel(streamID: "s", live: live, catalog: FixtureCatalogService(), now: { clock.now })
    }

    private func onAir() async -> (StubLive, LiveWatchModel) {
        let live = StubLive(LiveState(status: .live, playbackURL: URL(string: "https://x.test/p.m3u8")))
        let model = model(live)
        await model.load(language: .en)
        return (live, model)
    }

    @Test func leavingIsCountedOnce() async throws {
        let (live, model) = await onAir()
        model.setActive(true)
        try await until { await live.sent == [false] }
        model.setActive(false)
        model.setActive(false)
        try await until { await live.leaves == 1 }
        await model.settled()
        #expect(await live.sent == [false, true])
        model.player.stop()
    }

    @Test func aBeatOnItsWayWhenTheAppGoesToTheBackgroundCannotComeAfterTheLeave() async throws {
        let (live, model) = await onAir()
        await live.set(holdsBeats: true)
        model.setActive(true)
        try await until { await live.isBeatHeld }
        model.setActive(false)
        try await Task.sleep(for: .milliseconds(50))
        // Not cancelled, and the leave is not sent before it is answered
        #expect(await live.isBeatHeld)
        #expect(await live.sent == [false])
        await live.set(holdsBeats: false)
        await live.releaseBeat()
        try await until { await live.sent == [false, true] }
        model.player.stop()
    }

    @Test func aLeaveOnItsWayWhenTheViewerComesBackCannotComeAfterTheBeat() async throws {
        let (live, model) = await onAir()
        model.setActive(true)
        try await until { await live.beats == 1 }
        await live.set(holdsBeats: true)
        model.setActive(false)
        try await until { await live.isBeatHeld }
        model.setActive(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await live.sent == [false, true])
        await live.set(holdsBeats: false)
        await live.releaseBeat()
        try await until { await live.sent == [false, true, false] }
        model.setActive(false)
        model.player.stop()
    }

    @Test func toTheBackgroundAndBackWhileABeatIsOnItsWayEndsCountedIn() async throws {
        let (live, model) = await onAir()
        await live.set(holdsBeats: true)
        model.setActive(true)
        try await until { await live.isBeatHeld }
        model.setActive(false)
        model.setActive(true)
        // The new visit's reads are under way, and its beat is behind the leave
        try await Task.sleep(for: .milliseconds(50))
        #expect(await live.sent == [false])
        await live.set(holdsBeats: false)
        await live.releaseBeat()
        try await until { await live.sent == [false, true, false] }
        // The first visit's answer does not put the next beat off, nor bring another forward
        await model.poll()
        await model.settled()
        #expect(await live.sent == [false, true, false])
        model.setActive(false)
        model.player.stop()
    }

    @Test func aBeatThatFailsDoesNotStopTheLeave() async throws {
        let (live, model) = await onAir()
        await live.set(beatFails: true)
        model.setActive(true)
        try await until { await live.sent == [false] }
        model.setActive(false)
        try await until { await live.leaves == 1 }
        #expect(await live.sent == [false, true])
        model.player.stop()
    }

    @Test func thereIsOneRunHoweverOftenItIsTurnedOnAndOff() async throws {
        let live = StubLive(
            LiveState(status: .live, playbackURL: URL(string: "https://x.test/p.m3u8"), chat: .init(enabled: true)))
        let model = model(live)
        await model.load(language: .en)
        await live.set(isSlow: true)
        for _ in 0..<5 {
            model.setActive(true)
            try await Task.sleep(for: .milliseconds(30))
            model.setActive(false)
        }
        model.setActive(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await live.chatReads > 1)
        #expect(await live.mostChatReads == 1)
        model.setActive(false)
        await model.settled()
        model.player.stop()
    }

    @Test func aNewRunWaitsForTheOneThatWasEnded() async throws {
        let (live, model) = await onAir()
        await live.set(holdsState: true)
        clock.advance(60)
        model.setActive(true)
        try await until { await live.isStateHeld }
        // Its read does not end with it: nothing is read beside it
        for _ in 0..<3 {
            model.setActive(false)
            model.setActive(true)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await live.stateReads == 2)
        await live.set(holdsState: false)
        await live.releaseState()
        try await until { await live.stateReads == 3 }
        try await until { await live.sent == [false] }
        model.setActive(false)
        await model.settled()
        model.player.stop()
    }

    @Test func anAnswerFromBeforeTheBackgroundDoesNotPutOffComingBack() async throws {
        let (live, model) = await onAir()
        await live.set(holdsBeats: true)
        model.setActive(true)
        try await until { await live.isBeatHeld }
        model.setActive(false)
        // Answered while the app is in the background
        await live.set(holdsBeats: false)
        await live.releaseBeat()
        try await until { await live.sent == [false, true] }
        await model.settled()
        // Counted in at once, not when that answer's 20 seconds are over
        model.setActive(true)
        try await until { await live.sent == [false, true, false] }
        model.setActive(false)
        model.player.stop()
    }

    @Test func anAnswerThatComesAfterTheScreenIsGoneSendsNoBeat() async throws {
        let (live, model) = await onAir()
        await live.set(holdsState: true)
        clock.advance(60)
        model.setActive(true)
        try await until { await live.isStateHeld }
        model.setActive(false)
        await live.set(holdsState: false)
        await live.releaseState()
        await model.settled()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await live.sent.isEmpty)
        model.player.stop()
    }
}

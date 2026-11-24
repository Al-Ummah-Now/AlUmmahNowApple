import Foundation
import Testing

@testable import AUNFeatures

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

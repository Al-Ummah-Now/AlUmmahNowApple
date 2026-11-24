import Foundation
import Testing

@testable import AUNPlayer

@MainActor struct PlaybackPositionStoreTests {
    private let defaults = UserDefaults(suiteName: "positions-\(UUID().uuidString)")!

    @Test func keepsOnlyTheLastVideo() {
        let store = PlaybackPositionStore(defaults: defaults)
        store.save(60, duration: 600, of: "a")
        #expect(store.position(of: "a") == 60)
        store.save(90, duration: 600, of: "b")
        #expect(store.position(of: "a") == nil)
        #expect(PlaybackPositionStore(defaults: defaults).position(of: "b") == 90)
    }

    @Test func aFinishedOrBarelyStartedVideoStartsOver() {
        let store = PlaybackPositionStore(defaults: defaults)
        store.save(60, duration: 600, of: "a")
        store.save(595, duration: 600, of: "a")
        #expect(store.position(of: "a") == nil)
        store.save(60, duration: 600, of: "a")
        store.save(3, duration: 600, of: "a")
        #expect(store.position(of: "a") == nil)
        // The first seconds of another video don't cost the one that was kept.
        store.save(60, duration: 600, of: "a")
        store.save(3, duration: 600, of: "b")
        #expect(store.position(of: "a") == 60)
    }

    @Test func anOldOrBrokenEntryIsIgnored() {
        var date = Date(timeIntervalSince1970: 1_790_000_000)
        let store = PlaybackPositionStore(defaults: defaults, now: { date })
        store.save(60, duration: 600, of: "a")
        date += PlaybackPositionStore.lifetime - 1
        #expect(store.position(of: "a") == 60)
        date += 1
        #expect(store.position(of: "a") == nil)
        store.save(.nan, duration: 600, of: "a")
        store.save(60, duration: 0, of: "b")
        #expect(store.position(of: "b") == nil)
        defaults.set(Data("x".utf8), forKey: "player.lastPosition")
        #expect(store.position(of: "a") == nil)
    }
}

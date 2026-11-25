import AUNCoreBridge
import AUNDesign
import Foundation
import Testing

@testable import AUNFeatures

@Suite("ViewerSafetyTests")
struct ViewerSafetyTests {
    @Test func reportURLsUsePublicReportRouteLocaleHostAndEncoding() {
        let prodWeb = AppEnvironment(name: "prod", apiBaseURL: URL(string: "https://videos.api.alummahnow.net")!).webBaseURL
        let qaWeb = AppEnvironment.qa.webBaseURL
        #expect(prodWeb.absoluteString == "https://videos.alummahnow.net")
        #expect(qaWeb.absoluteString == "https://videos.qa.alummahnow.net")
        #expect(
            ViewerReportURL.video(id: "v 123", language: "en", webBaseURL: prodWeb).absoluteString
                == "https://videos.alummahnow.net/en/report?type=video&id=v%20123"
        )
        #expect(
            ViewerReportURL.video(id: "v123", language: "ar", webBaseURL: prodWeb).absoluteString
                == "https://videos.alummahnow.net/ar/report?type=video&id=v123"
        )
        #expect(
            ViewerReportURL.channel(id: "c1", language: "en", webBaseURL: prodWeb).absoluteString
                == "https://videos.alummahnow.net/en/report?type=channel&id=c1"
        )
        #expect(
            ViewerReportURL.liveStream(id: "s1", language: "ar", webBaseURL: prodWeb).absoluteString
                == "https://videos.alummahnow.net/ar/report?type=livestream&id=s1"
        )
        #expect(
            ViewerReportURL.liveChat(streamID: "s1", messageID: "m9", language: "ar", webBaseURL: prodWeb).absoluteString
                == "https://videos.alummahnow.net/ar/report?type=live_chat&stream=s1&message=m9"
        )
        #expect(
            ViewerReportURL.video(id: "v1", language: "en", webBaseURL: qaWeb).absoluteString
                == "https://videos.qa.alummahnow.net/en/report?type=video&id=v1"
        )
    }

    @Test @MainActor func liveWatchModelSetBlockedStopsPlaybackAndSuppressesBeats() async throws {
        let clock = TestClock()
        let url = URL(string: "https://x.test/live.m3u8")!
        let live = StubLive(LiveState(status: .live, playbackURL: url, chat: .init(enabled: true)))
        let model = LiveWatchModel(streamID: "s1", live: live, catalog: FixtureCatalogService(), now: { clock.now })
        await model.load(language: .en)
        await model.tick()
        await model.settled()
        #expect(model.player.item != nil)
        let beatsBeforeBlock = await live.beats
        let statesBeforeBlock = await live.stateReads
        #expect(beatsBeforeBlock >= 1)

        model.setBlocked(true)
        try await until { await live.leaves == 1 }
        await model.settled()
        #expect(model.isBlocked)
        #expect(model.player.item == nil)
        #expect(await live.sent.last == true)

        // While blocked, polling must not read state, chat, or send viewer beats.
        clock.advance(120)
        await model.tick()
        await model.settled()
        #expect(await live.beats == beatsBeforeBlock)
        #expect(await live.stateReads == statesBeforeBlock)
        #expect(model.player.item == nil)

        // Unblocking resumes playback.
        model.setBlocked(false)
        for _ in 0..<50 {
            if model.player.item != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isBlocked)
        #expect(model.player.item != nil)
        model.close()
    }

    @Test func liveDTOsDecodeChannelIDAndChatUserID() throws {
        let streamJSON = Data(#"{"id":"s1","title":"Live","status":"live","channelId":"ch-7","channelName":"Dars"}"#.utf8)
        let stream = try JSONDecoder().decode(LiveStream.self, from: streamJSON)
        #expect(stream.channelID == "ch-7")

        let msgJSON = Data(#"{"id":"m1","userId":"u-42","authorName":"Amina","text":"Salam","offsetMs":100}"#.utf8)
        let msg = try JSONDecoder().decode(LiveChatMessage.self, from: msgJSON)
        #expect(msg.userID == "u-42")
    }

    @Test @MainActor func blockStoreUsesStableIDsAndAvoidsDisplayNameCollisions() {
        let suite = "AUNViewerSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ViewerBlockStore(defaults: defaults)
        store.blockChannel(id: "c1", name: "Daily Dars")
        store.blockChatUser(id: "u-bad", name: "Ahmad")

        // Same ID is blocked even if name changes; different ID with same display name is NOT blocked.
        #expect(store.isChannelBlocked(id: "c1", name: "Renamed"))
        #expect(!store.isChannelBlocked(id: "c2", name: "Daily Dars"))
        // Missing ID still falls back to case-insensitive name.
        #expect(store.isChannelBlocked(id: nil, name: "daily dars"))

        #expect(store.isChatUserBlocked(id: "u-bad", name: "Changed Name"))
        #expect(!store.isChatUserBlocked(id: "u-good", name: "Ahmad"))

        let messages = [
            LiveChatMessage(id: "m1", userID: "u-bad", authorName: "Ahmad", text: "spam", offsetMs: 1000),
            LiveChatMessage(id: "m2", userID: "u-good", authorName: "Ahmad", text: "Salam", offsetMs: 2000),
        ]
        #expect(store.filterMessages(messages).map(\.id) == ["m2"])

        let streams = [
            LiveStream(id: "s1", title: "Blocked", status: .live, channelID: "c1", channelName: "Daily Dars"),
            LiveStream(id: "s2", title: "Allowed", status: .live, channelID: "c2", channelName: "Daily Dars"),
        ]
        #expect(store.filterLiveStreams(streams).map(\.id) == ["s2"])

        // Reload from UserDefaults
        let reloaded = ViewerBlockStore(defaults: defaults)
        #expect(reloaded.entries.count == 2)
        #expect(reloaded.isChannelBlocked(id: "c1", name: nil))

        reloaded.unblock(id: ViewerBlockStore.channelKey(id: "c1", name: "Daily Dars"))
        #expect(!reloaded.isChannelBlocked(id: "c1", name: "Daily Dars"))
    }

    @Test @MainActor func unblockChannelRemovesNameStoredEntryEvenWhenIDNowPresent() {
        let suite = "AUNViewerSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ViewerBlockStore(defaults: defaults)
        store.blockChannel(id: nil, name: "Daily Dars")
        #expect(store.isChannelBlocked(id: "ch-99", name: "Daily Dars"))
        store.unblockChannel(id: "ch-99", name: "Daily Dars")
        #expect(!store.isChannelBlocked(id: "ch-99", name: "Daily Dars"))
        #expect(store.entries.isEmpty)
    }

    @Test @MainActor func filterRailsDropsEntireRailWhenAllChannelsAreBlocked() {
        let suite = "AUNViewerSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ViewerBlockStore(defaults: defaults)
        store.blockChannel(id: "c1", name: "Blocked Channel")
        let hidden = Video(id: "v1", title: "Hidden", channelID: "c1", channelName: "Blocked Channel")
        let rails = [HomeRail(kind: .recent, videos: [hidden])]
        #expect(store.filterRails(rails).isEmpty)
    }

    @Test func appEnvironmentWebBaseURLCoversQAStageProdAndFallback() {
        let qa = AppEnvironment.qa.webBaseURL
        let stage = AppEnvironment(name: "stage", apiBaseURL: URL(string: "https://videos.api.stage.alummahnow.net")!).webBaseURL
        let prod = AppEnvironment(name: "prod", apiBaseURL: URL(string: "https://videos.api.alummahnow.net")!).webBaseURL
        #expect(qa.absoluteString == "https://videos.qa.alummahnow.net")
        #expect(stage.absoluteString == "https://videos.stage.alummahnow.net")
        #expect(prod.absoluteString == "https://videos.alummahnow.net")
    }

    @Test @MainActor func liveWatchModelReChecksBlockedMidChatReadAndBumpsVisitMidBeat() async throws {
        let clock = TestClock()
        let url = URL(string: "https://x.test/live.m3u8")!
        let live = StubLive(LiveState(status: .live, playbackURL: url, chat: .init(enabled: true)))
        let model = LiveWatchModel(streamID: "s1", live: live, catalog: FixtureCatalogService(), now: { clock.now })
        await model.load(language: .en)
        await model.tick()
        await model.settled()
        let beatsAfterFirst = await live.beats
        #expect(beatsAfterFirst == 1)

        // Hold the next chat read mid-flight while a beat is also due, then block before chat returns:
        // the guard after refreshChat must prevent a new normal beat from firing.
        clock.advance(25)
        await live.set(holdsChat: true)
        let pollTask = Task { await model.poll() }
        try await until { await live.isChatHeld }
        model.setBlocked(true)
        await live.set(holdsChat: false)
        await live.releaseChat()
        await pollTask.value
        try await until { await live.leaves == 1 }
        await model.settled()
        #expect(await live.beats == beatsAfterFirst)
        #expect(await live.leaves == 1)

        // Unblock, hold a beat mid-flight, then block again before the beat answers:
        // visit bump must ignore the stale beat's viewer count and still send leave.
        model.setBlocked(false)
        await live.set(holdsBeats: true)
        let beatPoll = Task { await model.poll() }
        try await until { await live.isBeatHeld }
        model.setBlocked(true)
        await live.set(holdsBeats: false)
        await live.releaseBeat()
        await beatPoll.value
        try await until { await live.leaves == 2 }
        await model.settled()
        #expect(model.isBlocked)
        #expect(model.player.item == nil)
        model.close()
    }

    @Test @MainActor func liveWatchModelShowStopsPlaybackAndSendsLeaveWhenBlockedOutsideView() async throws {
        let clock = TestClock()
        let url = URL(string: "https://x.test/live.m3u8")!
        let live = StubLive(LiveState(status: .live, playbackURL: url, chat: .init(enabled: true)))
        let channelID = "ch-race-\(UUID().uuidString)"
        await live.set(channelID: channelID, channelName: "Race Channel")
        defer { ViewerBlockStore.shared.unblockChannel(id: channelID, name: "Race Channel") }

        let model = LiveWatchModel(streamID: "s-race", live: live, catalog: FixtureCatalogService(), now: { clock.now })
        await model.load(language: .en)
        await model.tick()
        await model.settled()
        #expect(model.player.item != nil)
        #expect(await live.beats == 1)

        // Block in the shared store without calling setBlocked(true) (simulates another window / onChange race),
        // then let refreshState -> show() land: must stop player and send leave.
        ViewerBlockStore.shared.blockChannel(id: channelID, name: "Race Channel")
        clock.advance(65)
        await model.tick()
        try await until { await live.leaves == 1 }
        await model.settled()
        #expect(model.isBlocked)
        #expect(model.player.item == nil)
        #expect(await live.leaves == 1)
        model.close()
    }

    @Test @MainActor func chatUserWithoutIDIsNotBlockedByNameAndUnnamedChannelStoresEmptyName() {
        let suite = "AUNViewerSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ViewerBlockStore(defaults: defaults)
        store.blockChatUser(id: nil, name: "Ahmad")
        store.blockChatUser(id: "   ", name: "Ahmad")
        #expect(store.entries.isEmpty)
        #expect(!store.isChatUserBlocked(id: nil, name: "Ahmad"))

        store.blockChannel(id: "ch-nameless", name: "")
        #expect(store.isChannelBlocked(id: "ch-nameless", name: nil))
        #expect(store.entries.first?.name == "")
    }

    @Test @MainActor func pauseForReportPausesWatchAndLivePlaybackWithoutClearingItem() async {
        let clock = TestClock()
        let url = URL(string: "https://x.test/live.m3u8")!
        let live = StubLive(LiveState(status: .live, playbackURL: url))
        let liveModel = LiveWatchModel(streamID: "s1", live: live, catalog: FixtureCatalogService(), now: { clock.now })
        await liveModel.load(language: .en)
        #expect(liveModel.player.item != nil)
        #expect(liveModel.player.player.timeControlStatus != .paused)
        liveModel.pauseForReport()
        #expect(liveModel.player.player.timeControlStatus == .paused)
        #expect(liveModel.player.item != nil)
        liveModel.close()

        let catalog = HeldCatalog()
        await catalog.release()
        let watchModel = WatchViewModel(videoID: "v1", catalog: catalog)
        await watchModel.load(language: .en)
        #expect(watchModel.player.item != nil)
        #expect(watchModel.player.player.timeControlStatus != .paused)
        watchModel.pauseForReport()
        #expect(watchModel.player.player.timeControlStatus == .paused)
        #expect(watchModel.player.item != nil)
        watchModel.player.stop()
    }

    @Test func allSafetyKeysLocalizeInEnglishAndArabic() {
        let keys = [
            "safety.moreActions", "safety.moreActionsFor", "safety.report.video", "safety.report.channel",
            "safety.report.stream", "safety.report.message", "safety.report.tvBody", "safety.report.tvStreamBody",
            "safety.report.tvMessageBody", "safety.report.qrLabel",
            "safety.block.channel", "safety.block.user", "safety.block.confirm", "safety.block.channelTitle",
            "safety.block.channelMessage", "safety.block.userTitle", "safety.block.userMessage",
            "safety.blocked.channelBanner", "safety.blocked.homeEmpty", "safety.blockedList.title",
            "safety.blockedList.emptyTitle", "safety.blockedList.emptyMessage", "safety.blockedList.kind.channel",
            "safety.blockedList.kind.user", "safety.unblock", "safety.unblockFor",
        ]
        for language in AppLanguage.allCases {
            let l10n = L10n(language)
            for key in keys {
                let value = l10n(key)
                #expect(!value.contains("⟦"), "Missing \(language.rawValue) string for \(key)")
                #expect(!value.isEmpty)
            }
        }
    }
}

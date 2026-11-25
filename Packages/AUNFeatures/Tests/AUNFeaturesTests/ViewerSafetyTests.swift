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

        // Unblock, hold a beat mid-flight, then block again before the beat answers: its answer is of a visit that is over.
        model.setBlocked(false)
        #expect(model.viewers == 5)
        await live.set(holdsBeats: true)
        let beatPoll = Task { await model.poll() }
        try await until { await live.isBeatHeld }
        await live.set(beatCount: 99)
        model.setBlocked(true)
        // Back before the answer is there: counted in again at once, whatever the old answer says of the next beat
        model.setBlocked(false)
        await live.set(holdsBeats: false)
        await live.releaseBeat()
        await beatPoll.value
        try await until { await live.leaves == 2 }
        await model.settled()
        #expect(model.viewers == 5)
        await live.set(beatCount: 7)
        let beatsBefore = await live.beats
        await model.poll()
        await model.settled()
        #expect(await live.beats == beatsBefore + 1)
        #expect(model.viewers == 7)
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

    /// A block that only `show` found, gone again before any page heard of it.
    @Test @MainActor func liveWatchModelUnblocksItselfWhenTheBlockItFoundIsGone() async throws {
        let clock = TestClock()
        let url = URL(string: "https://x.test/live.m3u8")!
        let live = StubLive(LiveState(status: .live, playbackURL: url, chat: .init(enabled: true)))
        let channelID = "ch-mirror-\(UUID().uuidString)"
        await live.set(channelID: channelID, channelName: "Mirror Channel")
        defer { ViewerBlockStore.shared.unblockChannel(id: channelID, name: "Mirror Channel") }
        let model = LiveWatchModel(streamID: "s-mirror", live: live, catalog: FixtureCatalogService(), now: { clock.now })
        ViewerBlockStore.shared.blockChannel(id: channelID, name: "Mirror Channel")
        await model.load(language: .en)
        #expect(model.isBlocked)
        model.step()
        #expect(model.isBlocked)

        ViewerBlockStore.shared.unblockChannel(id: channelID, name: "Mirror Channel")
        model.step()
        #expect(!model.isBlocked)
        try await until { model.player.item != nil }
        await model.poll()
        await model.settled()
        #expect(await live.beats == 1)
        model.close()
    }

    private static let web = URL(string: "https://videos.alummahnow.net")!

    @Test @MainActor func reportingPausesTheVideoAndClosingGoesOnOnlyIfItWasPlaying() async {
        let catalog = HeldCatalog()
        await catalog.release()
        let model = WatchViewModel(videoID: "v1", catalog: catalog)
        await model.load(language: .en)
        let request = ViewerReportRequest.video(id: "v1", language: "en", webBaseURL: Self.web)
        #expect(model.player.player.timeControlStatus != .paused)
        model.report(request)
        #expect(model.reportRequest == request)
        #expect(model.player.player.timeControlStatus == .paused)
        #expect(model.player.item != nil)
        model.reportClosed()
        #expect(model.reportRequest == nil)
        #expect(model.player.player.timeControlStatus != .paused)
        // Closed again by the cover's own binding: nothing more happens
        model.player.pause()
        model.reportClosed()
        #expect(model.player.player.timeControlStatus == .paused)
        // Paused by the viewer before: stays so
        model.report(request)
        model.reportClosed()
        #expect(model.player.player.timeControlStatus == .paused)
        model.player.stop()
    }

    @Test @MainActor func reportingAStreamOrMessagePausesItAndClosingGoesOnUnlessItIsBlockedOrGone() async {
        let url = URL(string: "https://x.test/live.m3u8")!
        func loaded() async -> LiveWatchModel {
            let live = StubLive(LiveState(status: .live, playbackURL: url))
            let model = LiveWatchModel(streamID: "s1", live: live, catalog: FixtureCatalogService(), now: { Date() })
            await model.load(language: .en)
            return model
        }
        let stream = ViewerReportRequest.liveStream(id: "s1", language: "ar", webBaseURL: Self.web)
        let message = ViewerReportRequest.liveChat(streamID: "s1", messageID: "m9", language: "ar", webBaseURL: Self.web)
        #expect(stream.titleKey == "safety.report.stream" && message.titleKey == "safety.report.message")
        #expect(message.url.absoluteString == "https://videos.alummahnow.net/ar/report?type=live_chat&stream=s1&message=m9")

        let model = await loaded()
        for request in [stream, message] {
            #expect(model.player.player.timeControlStatus != .paused)
            model.report(request)
            #expect(model.reportRequest == request)
            #expect(model.player.player.timeControlStatus == .paused)
            model.reportClosed()
            #expect(model.reportRequest == nil)
            #expect(model.player.player.timeControlStatus != .paused)
        }
        // Blocked, or the page gone, while the report was open
        model.report(stream)
        model.setBlocked(true)
        model.reportClosed()
        #expect(model.player.item == nil)
        #expect(model.player.player.timeControlStatus == .paused)
        model.close()
        let gone = await loaded()
        gone.report(stream)
        gone.close()
        gone.reportClosed()
        #expect(gone.player.player.timeControlStatus == .paused)
        // Paused by the viewer before: stays so
        let paused = await loaded()
        paused.player.pause()
        paused.report(stream)
        paused.reportClosed()
        #expect(paused.player.player.timeControlStatus == .paused)
        paused.close()
    }

    @Test func allSafetyKeysLocalizeInEnglishAndArabic() {
        let keys = [
            "safety.moreActions", "safety.moreActionsFor", "safety.report.video", "safety.report.channel",
            "safety.report.stream", "safety.report.message", "safety.report.tvBody", "safety.report.tvStreamBody",
            "safety.report.tvMessageBody", "safety.report.tvChatHint", "safety.report.qrLabel",
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

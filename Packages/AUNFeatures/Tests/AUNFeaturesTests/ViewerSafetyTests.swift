import AUNCoreBridge
import Foundation
import Testing

@testable import AUNFeatures

@Suite("ViewerSafetyTests")
struct ViewerSafetyTests {
    @Test func reportURLsUsePublicReportRouteLocaleHostAndEncoding() {
        #expect(
            ViewerReportURL.video(id: "v 123", language: "en").absoluteString
                == "https://videos.alummahnow.net/en/report?type=video&id=v%20123"
        )
        #expect(
            ViewerReportURL.video(id: "v123", language: "ar").absoluteString
                == "https://videos.alummahnow.net/ar/report?type=video&id=v123"
        )
        #expect(
            ViewerReportURL.channel(id: "c1", name: "Seerah", language: "en").absoluteString
                == "https://videos.alummahnow.net/en/report?type=channel&id=c1"
        )
        #expect(
            ViewerReportURL.liveStream(id: "s1", language: "ar").absoluteString
                == "https://videos.alummahnow.net/ar/report?type=livestream&id=s1"
        )
        #expect(
            ViewerReportURL.liveChat(streamID: "s1", messageID: "m9", language: "ar").absoluteString
                == "https://videos.alummahnow.net/ar/report?type=live_chat&stream=s1&message=m9"
        )
        let qaWeb = AppEnvironment.qa.webBaseURL
        #expect(qaWeb.absoluteString == "https://videos.qa.alummahnow.net")
        #expect(
            ViewerReportURL.video(id: "v1", language: "en", webBaseURL: qaWeb).absoluteString
                == "https://videos.qa.alummahnow.net/en/report?type=video&id=v1"
        )
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
}

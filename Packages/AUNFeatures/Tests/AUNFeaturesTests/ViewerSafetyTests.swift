import AUNCoreBridge
import Foundation
import Testing

@testable import AUNFeatures

@Suite("ViewerSafetyTests")
struct ViewerSafetyTests {
    @Test func reportURLsUseLocaleAndTarget() {
        #expect(
            ViewerReportURL.video(id: "v123", language: "en").absoluteString
                == "https://videos.alummahnow.net/en/video/v123?report=video"
        )
        #expect(
            ViewerReportURL.video(id: "v123", language: "ar").absoluteString
                == "https://videos.alummahnow.net/ar/video/v123?report=video"
        )
        #expect(
            ViewerReportURL.channel(id: "c1", name: "Seerah", language: "en").absoluteString
                == "https://videos.alummahnow.net/en/contact?from=app-report&type=channel&id=c1"
        )
        #expect(
            ViewerReportURL.liveChat(streamID: "s1", messageID: "m9", language: "ar").absoluteString
                == "https://videos.alummahnow.net/ar/contact?from=app-report&type=live_chat&stream=s1&message=m9"
        )
    }

    @Test @MainActor func blockStorePersistsFiltersAndUnblocks() {
        let suite = "AUNViewerSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ViewerBlockStore(defaults: defaults)
        store.blockChannel(id: "c1", name: "Spam Channel")
        store.blockChatUser(name: "TrollUser")

        #expect(store.isChannelBlocked(id: "c1", name: "Spam Channel"))
        #expect(store.isChannelBlocked(id: nil, name: "spam channel"))
        #expect(!store.isChannelBlocked(id: "c2", name: "Good Channel"))
        #expect(store.isChatUserBlocked(name: "trolluser"))

        let messages = [
            LiveChatMessage(id: "m1", authorName: "TrollUser", text: "spam", offsetMs: 1000),
            LiveChatMessage(id: "m2", authorName: "Amina", text: "Salam", offsetMs: 2000),
        ]
        #expect(store.filterMessages(messages).map(\.id) == ["m2"])

        // Reload from UserDefaults
        let reloaded = ViewerBlockStore(defaults: defaults)
        #expect(reloaded.entries.count == 2)
        #expect(reloaded.isChannelBlocked(id: "c1", name: nil))

        reloaded.unblock(id: ViewerBlockStore.channelKey(id: "c1", name: "Spam Channel"))
        #expect(!reloaded.isChannelBlocked(id: "c1", name: "Spam Channel"))
    }
}

import Foundation
import Testing

@testable import AUNCoreBridge

@Suite struct ChannelNameLocalizationTests {
    @Test func fixtureVideosNameTheChannelInArabic() {
        for video in FixtureCatalogService.videos {
            #expect(video.displayChannelName(.ar) == "الأمة الآن")
            #expect(video.displayChannelName(.en) == "Al Ummah Now")
        }
    }

    @Test func localizedChannelNameFallsBackToThePlainName() throws {
        let plainOnly = try JSONDecoder().decode(Video.self, from: Data(#"{"id":"a","channelName":"Chan"}"#.utf8))
        #expect(plainOnly.displayChannelName(.ar) == "Chan")

        let json = #"{"id":"b","channelName":"Chan","channelNameLocalized":{"en":"Chan","ar":" "}}"#
        let blankArabic = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
        #expect(blankArabic.displayChannelName(.ar) == "Chan")

        let localizedOnly = Video(id: "c", title: "", channelNameLocalized: LocalizedText(ar: "قناة"))
        #expect(localizedOnly.displayChannelName(.ar) == "قناة")
        #expect(localizedOnly.displayChannelName(.en) == nil)
        #expect(Video(id: "d", title: "").displayChannelName(.ar) == nil)
    }
}

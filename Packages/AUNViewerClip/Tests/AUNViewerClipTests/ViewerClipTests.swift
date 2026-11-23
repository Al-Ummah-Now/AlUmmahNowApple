import AUNCoreBridge
import Foundation
import Testing

@testable import AUNViewerClip

struct ViewerClipTests {
    @Test func resolvesVideoAndShortInvocationsFromWebAndShortLinks() {
        let shortLink = ClipInvocation.resolve(URL(string: "https://alummahnow.link/v/vid_10?t=45&lang=ar")!)
        #expect(shortLink == ClipInvocation(videoID: "vid_10", startSeconds: 45, language: .ar))

        let qaShort = ClipInvocation.resolve(URL(string: "https://qa.alummahnow.link/s/sh_99")!)
        #expect(qaShort == ClipInvocation(videoID: "sh_99", startSeconds: nil, language: nil))

        let webLink = ClipInvocation.resolve(URL(string: "https://videos.alummahnow.net/en/video/vid_77?t=12")!)
        #expect(webLink == ClipInvocation(videoID: "vid_77", startSeconds: 12, language: .en))

        // Playlists, channels, and Studio URLs are outside App Clip playback scope.
        #expect(ClipInvocation.resolve(URL(string: "https://alummahnow.link/l/pl_1")!) == nil)
        #expect(ClipInvocation.resolve(URL(string: "https://videos.alummahnow.net/en/studio")!) == nil)
    }

    @Test func enforcesFifteenMegabytePayloadCapAndKidsIsolation() {
        #expect(ClipInvocation.maxPayloadBytes == 15 * 1024 * 1024)
        var kidsVideo = FixtureCatalogService.videos[0]
        kidsVideo.category = "islamic_kids"
        #expect(ClipInvocation.isKidsSafeOnly(kidsVideo))
        #expect(!ClipInvocation.isKidsSafeOnly(FixtureCatalogService.videos[0]))
    }
}

import Foundation
import Testing

@testable import AUNCoreBridge

struct AppLinkTests {
    private func link(_ string: String) -> AppLink? { AppLink.parse(URL(string: string)!) }

    @Test(arguments: [
        "https://videos.alummahnow.net/en/video/v123", "https://videos.alummahnow.net/ar/video/v123",
        "https://videos.alummahnow.net/video/v123", "https://videos.qa.alummahnow.net/en/video/v123?t=42",
        "https://videos.stage.alummahnow.net/ar/video/v123/",
    ])
    func videoLinksInEveryLocaleAndHost(_ url: String) {
        #expect(link(url) == .video(id: "v123"))
        #expect(link(url)?.videoID == "v123")
    }

    @Test func shortsPlaylistsAndPosts() {
        #expect(link("https://videos.alummahnow.net/ar/shorts/s9") == .short(id: "s9"))
        #expect(link("https://videos.alummahnow.net/shorts/s9")?.videoID == "s9")
        #expect(link("https://videos.alummahnow.net/en/playlist/p1") == .playlist(id: "p1"))
        #expect(link("https://videos.alummahnow.net/ar/post/x7") == .post(id: "x7"))
        #expect(link("https://videos.alummahnow.net/en/playlist/p1")?.videoID == nil)
    }

    @Test func channelHandlesIncludingArabicAndSubpages() {
        #expect(link("https://videos.alummahnow.net/en/@main") == .channel(handle: "main"))
        #expect(link("https://videos.alummahnow.net/@main/videos") == .channel(handle: "main"))
        let arabic = "https://videos.alummahnow.net/ar/@" + "قناة".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        #expect(link(arabic) == .channel(handle: "قناة"))
        #expect(link("https://videos.alummahnow.net/en/@") == nil)
    }

    @Test func studioAddressesMapToSections() {
        #expect(link("https://videos.alummahnow.net/en/studio") == .studio(StudioLink(section: .home)))
        #expect(link("https://videos.alummahnow.net/studio/c1") == .studio(StudioLink(channelID: "c1", section: .home)))
        #expect(
            link("https://videos.alummahnow.net/ar/studio/c1/dashboard") == .studio(StudioLink(channelID: "c1", section: .home)))
        #expect(
            link("https://videos.alummahnow.net/en/studio/c1/analytics")
                == .studio(StudioLink(channelID: "c1", section: .analytics)))
        #expect(
            link("https://videos.alummahnow.net/en/studio/c1/content/videos")
                == .studio(StudioLink(channelID: "c1", section: .content)))
        #expect(
            link("https://videos.alummahnow.net/en/studio/c1/content/videos/v1/edit")
                == .studio(StudioLink(channelID: "c1", section: .content)))
        #expect(
            link("https://videos.alummahnow.net/en/studio/c1/content/videos/v1/analytics")
                == .studio(StudioLink(channelID: "c1", section: .analytics)))
        #expect(
            link("https://videos.alummahnow.net/en/studio/c1/content/deleted")
                == .studio(StudioLink(channelID: "c1", section: .deleted)))
        #expect(link("https://videos.alummahnow.net/en/studio/video/v1/edit") == .studio(StudioLink(section: .content)))
        #expect(link("https://videos.alummahnow.net/en/studio/video/v1/analytics") == .studio(StudioLink(section: .analytics)))
        #expect(link("https://videos.alummahnow.net/en/studio/go/upload") == .studio(StudioLink(section: .home)))
        #expect(link("https://videos.alummahnow.net/en/studio/c1/site") == .studio(StudioLink(channelID: "c1", section: .home)))
    }

    @Test func appPrefixedStudioAndAuthCallback() {
        #expect(
            link("https://videos.alummahnow.net/app/studio/c1/analytics")
                == .studio(StudioLink(channelID: "c1", section: .analytics)))
        let callback = URL(string: "https://videos.qa.alummahnow.net/app/auth/callback?code=abc&state=xyz")!
        #expect(AppLink.parse(callback) == .authCallback(callback))
        #expect(link("https://videos.alummahnow.net/app/auth/other") == nil)
        #expect(link("https://videos.alummahnow.net/app/settings") == nil)
    }

    @Test(arguments: [
        "http://videos.alummahnow.net/en/video/v1",  // not https
        "https://evil.example/en/video/v1",  // not our host
        "https://alummahnow.net/en/video/v1",  // www does not claim these
        "https://videos.alummahnow.net/",  // home
        "https://videos.alummahnow.net/en",
        "https://videos.alummahnow.net/en/video",  // no id
        "https://videos.alummahnow.net/en/explore",
        "alummahnow-studio://auth/callback?code=1",
    ])
    func foreignOrIncompleteURLsAreIgnored(_ url: String) {
        #expect(link(url) == nil)
    }

    @Test func hostMatchingIgnoresCase() {
        #expect(link("https://Videos.AlUmmahNow.net/en/video/v1") == .video(id: "v1"))
    }
}

struct FixtureClipTests {
    @Test func playableFixturesStreamTheBundledClipOthersNever() async throws {
        #expect(FixtureCatalogService.playableClip != nil)
        let playable = try await FixtureCatalogService(playable: true).video(id: "fixture-1")
        #expect(playable.playURL == FixtureCatalogService.playableClip)
        #expect(playable.playURL?.isFileURL == true)
        let plain = try await FixtureCatalogService().video(id: "fixture-1")
        #expect(plain.playURL?.host() == "fixtures.invalid")
        let rails = try await FixtureCatalogService(playable: true).homeRails(limit: 2)
        #expect(rails.flatMap(\.videos).allSatisfy { $0.playURL == FixtureCatalogService.playableClip })
    }
}

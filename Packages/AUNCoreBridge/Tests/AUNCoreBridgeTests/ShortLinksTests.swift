import AUNCoreBridge
import Foundation
import Testing

struct ShortLinksTests {
    private let site = URL(string: "https://videos.alummahnow.net")!
    private let page = URL(string: "https://videos.alummahnow.net/en/video/abc")!

    @Test(arguments: [
        (ShortLinks.Target.video("abc"), "/v/abc"),
        (.short("abc"), "/s/abc"),
        (.channel(id: "abc"), "/c/abc"),
        (.channel(id: "abc", handle: "@a.b"), "/@a.b"),
        (.post("abc"), "/p/abc"),
        (.playlist("abc"), "/l/abc"),
    ])
    func routes(target: ShortLinks.Target, path: String) {
        #expect(link(target)?.absoluteString == "https://alummahnow.link" + path)
        #expect(link(target, language: .ar)?.absoluteString == "https://alummahnow.link" + path + "?lang=ar")
        #expect(link(target, isPrivate: true) == nil)
    }

    @Test func videoOptions() {
        #expect(
            link(.video("v-1_2"), language: .ar, time: 42, playlist: .init(id: "abc", index: 0))?.query()
                == "t=42&list=abc&index=0&lang=ar")
        #expect(link(.video("abc"), time: 0, playlist: .init(id: "abc", index: -1))?.query() == "list=abc")
        #expect(link(.video("abc"), time: -1, playlist: .init(id: "bad/list", index: 1))?.query() == nil)
        #expect(link(.short("abc"), time: 42, playlist: .init(id: "abc", index: 1))?.query() == nil)
    }

    @Test(arguments: [
        "localhost:3092", "https://videos.dev.alummahnow.net", "videos.pr-123.alummahnow.net",
        "videos.preview.alummahnow.net", "alummahnow.net.example.com",
    ])
    func unsupportedOrigins(host: String) {
        #expect(ShortLinks.shortLinkOriginFor(host) == nil)
        let local = URL(string: "http://localhost:3092")!
        #expect(
            ShortLinks.shareURL(for: .video("abc"), siteOrigin: local, fallback: page, language: .en, isPrivate: false) == page)
    }

    @Test func supportedOrigins() {
        #expect(ShortLinks.shortLinkOriginFor("https://VIDEOS.API.ALUMMAHNOW.NET:443/path")?.host() == "alummahnow.link")
        #expect(ShortLinks.shortLinkOriginFor("videos.api.stage.alummahnow.net")?.host() == "stage.alummahnow.link")
        #expect(ShortLinks.shortLinkOriginFor("videos.api.qa.alummahnow.net")?.host() == "qa.alummahnow.link")
        #expect(ShortLinks.shortLinkOriginFor("qa.alummahnow.link")?.host() == "qa.alummahnow.link")
    }

    @Test(arguments: ["", "عربي", "a/b", "a?b", "abc\n", "_abc", String(repeating: "a", count: 65)])
    func invalidIDsFallBack(id: String) {
        #expect(link(.video(id)) == page)
        #expect(link(.video(id), isPrivate: true) == nil)
    }

    @Test func validationBoundaries() {
        #expect(link(.video(String(repeating: "a", count: 64))) != page)
        #expect(link(.channel(id: "abc", handle: "ab.")) == page)
        #expect(link(.channel(id: "abc", handle: "@@abc")) == page)
        #expect(link(.channel(id: "abc", handle: "عربي")) == page)
    }

    @Test func watchVideoUsesCatalogFormatAndVisibility() throws {
        let decoder = JSONDecoder()
        let privateShort = try decoder.decode(
            Video.self, from: Data(#"{"id":"abc","isShort":true,"isPublic":false}"#.utf8))
        #expect(privateShort.isShort)
        #expect(privateShort.isPrivate)

        let unlisted = try decoder.decode(
            Video.self, from: Data(#"{"id":"abc","isPublic":false,"isUnlisted":true}"#.utf8))
        #expect(!unlisted.isPrivate)

        let legacy = try decoder.decode(Video.self, from: Data(#"{"id":"abc"}"#.utf8))
        #expect(!legacy.isShort)
        #expect(!legacy.isPrivate)
    }

    private func link(
        _ target: ShortLinks.Target, language: AppLanguage = .en, isPrivate: Bool = false,
        time: Int? = nil, playlist: ShortLinks.PublicPlaylist? = nil
    ) -> URL? {
        ShortLinks.shareURL(
            for: target, siteOrigin: site, fallback: page, language: language, isPrivate: isPrivate,
            startSeconds: time, playlist: playlist)
    }
}

import Foundation
import Testing

@testable import AUNCoreBridge

private let base = URL(string: "https://api.test")!

private func detail(_ id: String, status: String) -> String {
    """
    {"id":"\(id)","title":"Plain","titleLocalized":{"en":"Plain","ar":"عربي"},"channelName":"Chan","views":7,"duration":75,
    "uploadStatus":"\(status)","playUrl":"https://cdn.test/\(id)/playlist.m3u8","availableResolutions":["240p"],
    "dateCreated":"2026-11-07T00:24:09.606Z"}
    """
}

@Suite struct CatalogServiceTests {
    @Test func railsAreCompletedFromDetailsAndHideUnfinishedVideos() async throws {
        let session = StubURLProtocol.session { request in
            let path = request.url?.path ?? ""
            if path == "/api/videos/sections/trending" {
                return (200, [:], Data(#"{"data":[{"id":"ready","title":"Plain"},{"id":"busy","title":"Busy"}]}"#.utf8))
            }
            if path.contains("/sections/") { return (500, [:], Data()) }
            let id = path.split(separator: "/").last.map(String.init) ?? ""
            return (200, [:], Data(detail(id, status: id == "ready" ? "ready" : "uploading").utf8))
        }
        let rails = try await NativeCatalogService(baseURL: base, session: session).homeRails(limit: 5)
        #expect(rails.map(\.kind) == [.trending])
        #expect(rails[0].videos.map(\.id) == ["ready"])
        #expect(rails[0].videos[0].displayTitle(.ar) == "عربي")
        #expect(rails[0].videos[0].channelName == "Chan")
    }

    @Test func railsThrowWhenEverySectionFails() async {
        let session = StubURLProtocol.session { _ in (503, [:], Data()) }
        await #expect(throws: CoreError.self) {
            _ = try await NativeCatalogService(baseURL: base, session: session).homeRails(limit: 5)
        }
    }

    @Test func decodesSubtitlesAndChapters() async throws {
        let session = StubURLProtocol.session { request in
            if request.url?.path.hasSuffix("subtitles") == true {
                let body =
                    #"{"success":true,"data":{"tracks":[{"id":"1","language":"ar","label":"العربية","url":"https://x.test/ar","isDefault":true}]}}"#
                return (200, [:], Data(body.utf8))
            }
            let body =
                #"{"success":true,"chapters":{"chapters":[{"id":"c","startTime":15,"endTime":30,"title":"T","titleLocalized":{"ar":"ف"}}]}}"#
            return (200, [:], Data(body.utf8))
        }
        let service = NativeCatalogService(baseURL: base, session: session)
        let tracks = try await service.subtitles(videoID: "v")
        #expect(tracks.first?.language == "ar")
        #expect(tracks.first?.isDefault == true)
        let chapters = try await service.chapters(videoID: "v")
        #expect(chapters.first?.startTime == 15)
        #expect(chapters.first?.displayTitle(.ar) == "ف")
    }

    @Test func notFoundMapsToCoreError() async {
        let session = StubURLProtocol.session { _ in (404, [:], Data()) }
        await #expect(throws: CoreError.notFound) {
            _ = try await NativeCatalogService(baseURL: base, session: session).video(id: "x")
        }
    }

    @Test func localizedTextFallsBackOnEmpty() {
        let text = LocalizedText(en: "E", ar: "")
        #expect(text.value(for: .ar, fallback: "F") == "F")
        #expect(text.value(for: .en, fallback: "F") == "E")
    }

    @Test func environmentRejectsMissingOrInsecureValues() {
        #expect(AppEnvironment.fromInfoDictionary(nil) == .qa)
        #expect(AppEnvironment.fromInfoDictionary(["AUNAPIBaseURL": "http://x.test", "AUNEnvironment": "prod"]) == .qa)
        let prod = AppEnvironment.fromInfoDictionary(["AUNAPIBaseURL": "https://p.test", "AUNEnvironment": "prod"])
        #expect(prod.name == "prod")
    }
}

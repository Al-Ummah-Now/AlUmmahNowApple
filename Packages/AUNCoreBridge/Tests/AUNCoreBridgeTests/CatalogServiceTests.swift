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

    @Test func liveStreamStateChatAndRemindersDecodeAndFastFilterChecksLinks() async throws {
        let session = StubURLProtocol.session { request in
            let path = request.url?.path ?? ""
            if path == "/api/live-streams/ls1" {
                let body = """
                    {"success":true,"result":{"stream":{"id":"ls1","title":"Friday Khutbah","status":"live",\
                    "kind":"premiere","premiereVideoId":"v1","eventType":"jumuah","channelId":"ch1",\
                    "channelName":"Masjid","playbackUrl":"https://live.test/ls1.m3u8","currentViewers":42}}}
                    """
                return (200, [:], Data(body.utf8))
            }
            if path == "/api/live-streams/ls1/state" {
                let body = """
                    {"success":true,"result":{"streamId":"ls1","sessionId":"s1","status":"live","sessionStatus":"live",\
                    "receiving":true,"playbackUrl":"https://live.test/ls1.m3u8","viewers":42,"kind":"premiere",\
                    "premiereVideoId":"v1","eventType":"jumuah","dvrWindowSeconds":7200,\
                    "chat":{"enabled":true,"replayEnabled":true,"slowModeSeconds":10,"subscribersOnly":true},\
                    "reminders":{"enabled":true,"count":9,"viewerSubscribed":false}}}
                    """
                return (200, [:], Data(body.utf8))
            }
            if path == "/api/live-streams/ls1/chat" {
                if request.httpMethod == "POST" {
                    let body = """
                        {"success":true,"result":{"message":{"id":"m2","streamId":"ls1","userId":"u1",\
                        "authorName":"Me","text":"Salam","offsetMs":15000,"isPinned":false}}}
                        """
                    return (200, [:], Data(body.utf8))
                }
                let body = """
                    {"success":true,"result":{"messages":[{"id":"m1","streamId":"ls1","userId":"u2",\
                    "authorName":"Ahmad","authorRole":"owner","text":"Welcome","offsetMs":5000,"isPinned":true}],\
                    "pinnedMessage":{"id":"m1","streamId":"ls1","userId":"u2","authorName":"Ahmad",\
                    "authorRole":"owner","text":"Welcome","offsetMs":5000,"isPinned":true},\
                    "settings":{"enabled":true,"replayEnabled":true,"slowModeSeconds":10,"subscribersOnly":true},\
                    "canModerate":true}}
                    """
                return (200, [:], Data(body.utf8))
            }
            if path == "/api/live-streams/ls1/reminders" {
                let body = #"{"success":true,"result":{"subscribed":true,"count":10}}"#
                return (200, [:], Data(body.utf8))
            }
            if path == "/api/live-streams/ls1/viewers" {
                let body = #"{"success":true,"result":{"viewers":43}}"#
                return (200, [:], Data(body.utf8))
            }
            return (200, [:], Data(#"{"success":true}"#.utf8))
        }
        let service = NativeCatalogService(baseURL: base, session: session)
        let stream = try await service.liveStream(id: "ls1")
        #expect(stream.id == "ls1")
        #expect(stream.kind == .premiere)
        #expect(stream.eventType == .jumuah)

        let state = try await service.liveStreamState(id: "ls1")
        #expect(state.status == .live)
        #expect(state.chat.enabled)
        #expect(state.chat.slowModeSeconds == 10)
        #expect(state.reminders.count == 9)

        let chat = try await service.liveChatMessages(streamID: "ls1")
        #expect(chat.messages.count == 1)
        #expect(chat.messages.first?.authorRole == .owner)
        #expect(chat.pinnedMessage?.id == "m1")
        #expect(chat.canModerate)

        let sent = try await service.postLiveChatMessage(streamID: "ls1", text: "Salam")
        #expect(sent.id == "m2")

        let reminder = try await service.setLiveReminder(streamID: "ls1", subscribed: true)
        #expect(reminder.viewerSubscribed)
        #expect(reminder.count == 10)

        let viewers = try await service.beatLiveViewer(streamID: "ls1", viewerID: "v_12345678")
        #expect(viewers == 43)

        #expect(LiveChatFastFilter.check("Assalamu alaikum") == nil)
        #expect(LiveChatFastFilter.check("Visit https://spam.invalid") == .urlBlocked)
        #expect(LiveChatFastFilter.check("Visit https://alummahnow.net", canPostLinks: true) == nil)
        #expect(LiveChatFastFilter.check("aaaaaaaaaaaa") == .spamRepetition)
    }
}

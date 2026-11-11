import Foundation
import Testing

@testable import AUNCoreBridge

struct TitlePatternTests {
    private let date = Date(timeIntervalSince1970: 1_794_355_200)  // 2026-11-11 00:00 UTC
    private let utc = TimeZone(identifier: "UTC")!

    @Test func defaultPatternIsTheFileNameWithoutExtension() {
        #expect(TitlePattern.render(TitlePattern.defaultPattern, .init(filename: "Lesson 3.mov")) == "Lesson 3")
    }

    @Test func tokensFillPerFile() {
        let context = TitlePattern.Context(
            filename: "a.mp4", index: 2, firstEpisode: 10, channelName: "Tafsir", date: date, timeZone: utc)
        #expect(
            TitlePattern.render("{{channel_name}} — Episode {{episode}} ({{n}}) {{date}}", context)
                == "Tafsir — Episode 12 (3) 2026-11-11")
        #expect(TitlePattern.render("{{year}}/{{month}}/{{day}}", context) == "2026/11/11")
    }

    @Test func hijriTokensUseUmmAlQura() {
        let context = TitlePattern.Context(filename: "a.mp4", date: date, language: .en, timeZone: utc)
        #expect(TitlePattern.render("{{hijri_year}}", context) == "1448")
        #expect(!TitlePattern.render("{{hijri_month}}", context).isEmpty)
    }

    @Test func unknownTokensStayAndEmptyFallsBackToTheFileName() {
        #expect(TitlePattern.render("{{surah}} x", .init(filename: "a.mp4")) == "{{surah}} x")
        #expect(TitlePattern.render("  ", .init(filename: "clip.mp4")) == "clip")
    }

    @Test func schedulesSpreadByInterval() {
        let settings = UploadSettings(scheduleAt: date, scheduleIntervalMinutes: 90)
        #expect(settings.scheduleDate(at: 2) == date.addingTimeInterval(3 * 60 * 60))
        #expect(UploadSettings().scheduleDate(at: 1) == nil)
    }
}

struct UploadServiceTests {
    private let base = URL(string: "https://videos.api.qa.alummahnow.net")!

    private func service(_ handler: @escaping StubURLProtocol.Handler) -> NativeStudioService {
        NativeStudioService(
            baseURL: base, accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]),
            session: StubURLProtocol.session(handler: handler))
    }

    @Test func initiateSendsTheChannelHeaderAndCommaTags() async throws {
        let ticket = try await service { request in
            #expect(request.url?.path() == "/api/videos/upload/initiate")
            #expect(request.value(forHTTPHeaderField: "channelId") == "c1")
            let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            #expect(body?["tags"] as? String == "a,b")
            #expect(body?["isPublic"] as? Bool == false)
            #expect(body?["isDraft"] as? Bool == true)
            #expect(body?["fileSize"] as? Int == 42)
            let reply = #"{"success":true,"result":{"videoId":"v1","tusSessionId":"s1","chunkSize":52428800,"resumable":true}}"#
            return (200, [:], Data(reply.utf8))
        }.initiateUpload(
            UploadInitiation(
                title: "T", description: nil, fileSize: 42, mimeType: "video/mp4", isPublic: false, isDraft: true,
                tags: "a,b", category: "fiqh"), channelID: "c1")
        #expect(ticket == UploadTicket(videoID: "v1", tusSessionID: "s1", chunkSize: 52_428_800))
    }

    @Test func scheduleSendsUTCAndTheTimeZone() async throws {
        try await service { request in
            #expect(request.url?.path() == "/api/videos/v1/schedule")
            let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            #expect((body?["scheduledPublishDate"] as? String)?.hasSuffix("Z") == true)
            #expect(body?["timezone"] as? String == "Asia/Riyadh")
            return (200, [:], Data(#"{"success":true}"#.utf8))
        }.schedule(
            videoID: "v1", at: Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "Asia/Riyadh")!,
            channelID: "c1")
    }

    @Test func playlistsFollowTheCursor() async throws {
        let playlists = try await service { request in
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "cursor" }?.value
            let page =
                cursor == nil
                ? #"{"cursor":"p2","limit":100,"data":[{"id":"p1","title":"One","isPublic":false}]}"#
                : #"{"cursor":null,"limit":100,"data":[{"id":"p2","title":"Two"}]}"#
            return (200, [:], Data(page.utf8))
        }.playlists(channelID: "c1")
        #expect(playlists.map(\.id) == ["p1", "p2"])
        #expect(playlists[0].isPublic == false)
    }
}

struct TUSTransferTests {
    @Test func createOffsetAndChunk() async throws {
        let handler: StubURLProtocol.Handler = { request in
            switch request.httpMethod {
            case "POST":
                #expect(request.value(forHTTPHeaderField: "Upload-Length") == "5")
                #expect(request.value(forHTTPHeaderField: "Upload-Metadata")?.contains("tusSessionId czE=") == true)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
                return (201, ["Location": "/api/videos/tus/s1.v1"], Data())
            case "HEAD": return (200, ["Upload-Offset": "2"], Data())
            default:
                #expect(request.value(forHTTPHeaderField: "Upload-Offset") == "2")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/offset+octet-stream")
                return (204, ["Upload-Offset": "5"], Data())
            }
        }
        let session = StubURLProtocol.session(handler: handler)
        let transfer = TUSTransfer(chunkConfiguration: session.configuration, control: session)
        let endpoint = URL(string: "https://videos.api.qa.alummahnow.net/api/videos/tus")!
        let location = try await transfer.create(
            endpoint: endpoint, headers: ["Authorization": "Bearer t"], size: 5, metadata: ["tusSessionId": "s1"])
        #expect(location.absoluteString == "https://videos.api.qa.alummahnow.net/api/videos/tus/s1.v1")
        #expect(try await transfer.offset(of: location, headers: [:]) == 2)
        let chunk = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("abc".utf8).write(to: chunk)
        let next = try await transfer.send(chunk: chunk, to: location, offset: 2, headers: [:]) { _ in }
        #expect(next == 5)
    }

    @Test func refusedChunksMapOntoCoreErrors() async throws {
        let session = StubURLProtocol.session { _ in (401, [:], Data()) }
        let transfer = TUSTransfer(chunkConfiguration: session.configuration, control: session)
        let chunk = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("abc".utf8).write(to: chunk)
        await #expect(throws: CoreError.signInRequired) {
            try await transfer.send(chunk: chunk, to: URL(string: "https://x.invalid/tus/1")!, offset: 0, headers: [:]) { _ in }
        }
    }
}

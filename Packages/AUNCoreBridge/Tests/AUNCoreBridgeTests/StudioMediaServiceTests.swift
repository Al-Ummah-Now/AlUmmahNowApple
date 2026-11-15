import Foundation
import Testing

@testable import AUNCoreBridge

/// The captions, institution, insights and renditions routes against a fake HTTP server.
struct StudioMediaServiceTests {
    private let base = URL(string: "https://videos.api.qa.alummahnow.net")!

    private func service(_ handler: @escaping StubURLProtocol.Handler) -> NativeStudioService {
        NativeStudioService(
            baseURL: base, accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]),
            session: StubURLProtocol.session(handler: handler))
    }

    private func json(_ text: String, status: Int = 200) -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/json"], Data(text.utf8))
    }

    private func object(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]) ?? [:]
    }

    private func parsed(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Captions

    @Test func draftsListDecodesOriginsCountsAndActsAsTheChannel() async throws {
        let list = try await service { request in
            #expect(request.url?.path() == "/api/videos/v1/captions/drafts")
            #expect(request.value(forHTTPHeaderField: "channelId") == "c1")
            return json(
                """
                {"success":true,"data":{"drafts":[
                  {"language":"ar","version":3,"kind":"source","origin":"on_device","edited":true,"cues":12,"pendingQuran":2,
                   "updatedAt":"2026-11-14T10:00:00.000Z","track":"none"},
                  {"language":"en","version":2,"kind":"translation","origin":"translation","edited":false,"cues":9,
                   "pendingQuran":0,"updatedAt":"2026-11-14T10:00:00Z","publishedVersion":1,"track":"machine"},
                  {"language":"fr","version":1,"origin":"something_new","cues":1,"updatedAt":"x","track":"later"}
                ],"claims":[{"language":"ur","status":"queued","requestedAt":"2026-11-14T10:00:00Z"}],"transcriptAvailable":true}}
                """)
        }.captionDrafts(videoID: "v1", channelID: "c1")
        #expect(list.drafts.map(\.language) == ["ar", "en", "fr"])
        #expect(list.drafts[0].origin == .onDevice)
        #expect(list.drafts[0].cueCount == 12)
        #expect(list.drafts[0].pendingQuran == 2)
        #expect(list.drafts[1].isOutdated)
        #expect(list.drafts[2].origin == nil)
        #expect(list.drafts[2].track == .none)
        #expect(list.claims == [CaptionClaim(language: "ur", status: .queued)])
        #expect(list.transcriptAvailable)
    }

    @Test func oneDraftKeepsQuranSegmentsExactlyWhenSaved() async throws {
        let draftJSON = """
            {"success":true,"data":{"language":"ar","version":4,"kind":"source","origin":"transcription","edited":false,
            "cueCount":2,"pendingQuran":1,"updatedAt":"2026-11-14T10:00:00Z","track":"none","cues":[
              {"id":"c1","startMs":0,"endMs":2000,"segments":[{"type":"speech","text":"بسم الله"}]},
              {"id":"c2","startMs":2000,"endMs":9000,"segments":[{"type":"quran","range":"1:1:1-1:1:4","status":"review",
               "alternatives":["27:30:3-27:30:6"],"heard":"بسم الله الرحمن الرحيم"},{"type":"speech","text":"  "}]}
            ]}}
            """
        let draft = try await service { _ in json(draftJSON) }.captionDraft(videoID: "v1", language: "ar", channelID: nil)
        #expect(draft.summary.cueCount == 2)
        #expect(draft.cues[1].hasQuran)
        let sent = LockedBox<Data>(Data())
        _ = try await service { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path() == "/api/videos/v1/captions/drafts/ar")
            sent.value = StubURLProtocol.body(of: request)
            return json(
                #"{"success":true,"data":{"language":"ar","version":5,"origin":"transcription","edited":true,"cues":2,"track":"none"}}"#
            )
        }.saveCaptionDraft(videoID: "v1", language: "ar", baseVersion: 4, cues: draft.cues, channelID: nil)
        #expect(parsed(sent.value)["baseVersion"] as? Int == 4)
        let cues = parsed(sent.value)["cues"] as? [[String: Any]] ?? []
        let quran = (cues.last?["segments"] as? [[String: Any]])?.first ?? [:]
        #expect(quran["type"] as? String == "quran")
        #expect(quran["range"] as? String == "1:1:1-1:1:4")
        #expect(quran["status"] as? String == "review")
        #expect(quran["alternatives"] as? [String] == ["27:30:3-27:30:6"])
        #expect(quran["heard"] as? String == "بسم الله الرحمن الرحيم")
        // The blank speech segment is dropped before saving; the server refuses empty text.
        #expect((cues.last?["segments"] as? [Any])?.count == 1)
    }

    @Test func conflictsCarryTheServerCode() async {
        await #expect(throws: CoreError.conflict("draft_conflict")) {
            try await service { _ in json(#"{"success":false,"error":"draft_conflict","version":7}"#, status: 409) }
                .publishCaptionDraft(videoID: "v1", language: "ar", baseVersion: 6, replaceUpload: false, channelID: nil)
        }
        await #expect(throws: CoreError.conflict("draft_exists")) {
            try await service { _ in json(#"{"success":false,"error":"draft_exists"}"#, status: 409) }
                .submitOnDeviceTranscript(
                    videoID: "v1", language: "ar",
                    transcript: OnDeviceTranscript(
                        segments: [TranscriptSegment(startMs: 0, endMs: 900, text: "x")], engine: TranscriptEngine(model: "base")),
                    channelID: nil)
        }
    }

    @Test func onDeviceTranscriptSendsSegmentsEngineAndReplace() async throws {
        let sent = LockedBox<Data>(Data())
        let count = try await service { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path() == "/api/videos/v1/captions/drafts/ar/transcript")
            sent.value = StubURLProtocol.body(of: request)
            return json(#"{"success":true,"data":{"status":"queued","segments":2}}"#, status: 202)
        }.submitOnDeviceTranscript(
            videoID: "v1", language: "ar",
            transcript: OnDeviceTranscript(
                segments: [
                    TranscriptSegment(startMs: 0, endMs: 1500, text: "السلام عليكم"),
                    TranscriptSegment(startMs: 1500, endMs: 3000, text: "ورحمة الله"),
                ],
                engine: TranscriptEngine(model: "large-v3-turbo-q5_0"), replace: true),
            channelID: "c1")
        #expect(count == 2)
        #expect((parsed(sent.value)["segments"] as? [[String: Any]])?.first?["text"] as? String == "السلام عليكم")
        #expect(
            (parsed(sent.value)["engine"] as? [String: String]) == ["provider": "whisper.cpp", "model": "large-v3-turbo-q5_0"])
        #expect(parsed(sent.value)["replace"] as? Bool == true)
    }

    @Test func jobsAndMinutes() async throws {
        let job = try await service { request in
            #expect(request.url?.path() == "/api/videos/v1/captions/jobs")
            return json(
                """
                {"success":true,"data":{"existing":false,"job":{"id":"j1","videoId":"v1","language":"ar","replace":false,
                "status":"waiting_budget","progress":null,"minutesReserved":12,"minutesCharged":null,"waived":false,
                "error":null,"createdAt":"2026-11-14T10:00:00Z","updatedAt":"2026-11-14T10:00:00Z","finishedAt":null}}}
                """, status: 202)
        }.startCaptionJob(videoID: "v1", language: "ar", replace: false, channelID: nil)
        #expect(job.status == .waitingBudget)
        #expect(job.isActive)
        let minutes = try await service { _ in
            json(
                """
                {"success":true,"data":{"minutesNeeded":12,"usage":{"period":"2026-11","resetsAt":"2026-12-01T00:00:00Z",
                "unlimited":false,"via":"tier","tierMinutes":300,"monthGranted":0,"monthLimit":300,"monthUsed":84,
                "packsRemaining":0,"overdraft":0,"held":12,"remaining":216,"warning":false}}}
                """)
        }.captionMinutes(videoID: "v1", channelID: nil)
        #expect(minutes.remaining == 216)
        #expect(minutes.minutesNeeded == 12)
        #expect(minutes.canStart)
        #expect(!minutes.hasNoPlan)
    }

    @Test func pathSegmentsCannotEscapeTheRoute() async throws {
        _ = try? await service { request in
            #expect(request.url?.path() == "/api/videos/_invalid_/captions/drafts")
            return json(#"{"success":true,"data":{"drafts":[]}}"#)
        }.captionDrafts(videoID: "../admin", channelID: nil)
    }

    // MARK: Institution

    @Test func brandKitRoundTripsAndTeamMembersReadOnly() async throws {
        let state = try await service { request in
            #expect(request.url?.path() == "/api/studio/brand-kit")
            #expect(request.value(forHTTPHeaderField: "channelId") == "c2")
            return json(
                """
                {"success":true,"data":{"saved":true,"canEdit":false,"kit":{"name":{"ar":"الأمة"},
                "colors":{"primary":"#ffa037","secondary":"#093041","text":"#f7f1e8","background":"#093041"},
                "logo":"0123456789abcdef","lowerThird":{"style":"box","position":"end"},"watermark":"bottom-end"}}}
                """)
        }.brandKit(channelID: "c2")
        #expect(!state.canEdit)
        #expect(state.kit.lowerThird == .init(style: .box, position: .end))
        #expect(state.kit.watermark == .bottomEnd)
        #expect(state.kit.displayName(.en) == "الأمة")
        let sent = LockedBox<Data>(Data())
        var kit = state.kit
        kit.name.en = "The Ummah"
        _ = try await service { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.value(forHTTPHeaderField: "channelId") == nil)
            sent.value = StubURLProtocol.body(of: request)
            return json(#"{"success":true,"data":{"kit":\#(String(data: StubURLProtocol.body(of: request), encoding: .utf8)!)}}"#)
        }.saveBrandKit(kit)
        #expect((parsed(sent.value)["name"] as? [String: String])?["en"] == "The Ummah")
        #expect(parsed(sent.value)["watermark"] as? String == "bottom-end")
        await #expect(throws: CoreError.forbidden) {
            try await service { _ in json(#"{"success":false,"error":"forbidden"}"#, status: 403) }.saveBrandKit(kit)
        }
    }

    @Test func assetsUploadRawBytesWithTheirName() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let asset = try await service { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path() == "/api/studio/assets")
            #expect(request.url?.query()?.contains("name=Logo") == true)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
            #expect(request.value(forHTTPHeaderField: "Content-Length") == "11")
            #expect(StubURLProtocol.body(of: request) == png)
            return json(
                #"{"success":true,"data":{"id":"0123456789abcdef","kind":"image","name":"Logo","contentType":"image/png","bytes":11,"createdAt":"2026-11-14T10:00:00Z"}}"#,
                status: 201)
        }.addAsset(name: "Logo", bytes: png)
        #expect(asset.kind == .image)
        await #expect(throws: CoreError.conflict("library_full")) {
            try await service { _ in json(#"{"success":false,"error":"library_full"}"#, status: 409) }
                .addAsset(name: "x", bytes: png)
        }
    }

    @Test func libraryRefusesBeforeUploading() {
        let library = StudioAssetLibrary(
            assets: [StudioAsset(id: "a", kind: .image, name: "a", contentType: "image/png", bytes: 900)],
            limits: .init(maxAssets: 2, maxAssetBytes: 500, maxTotalBytes: 1000))
        #expect(library.refusal(forFileOfSize: 0) == "empty")
        #expect(library.refusal(forFileOfSize: 501) == "too_large")
        #expect(library.refusal(forFileOfSize: 200) == "library_full")
        #expect(library.refusal(forFileOfSize: 100) == nil)
    }

    // MARK: Insights

    @Test func summaryMetricsAndRetention() async throws {
        let period = DateInterval(start: Date(timeIntervalSince1970: 1_794_000_000), duration: 7 * 86_400)
        let summary = try await service { request in
            #expect(request.url?.path() == "/api/analytics/summary")
            #expect(request.url?.query()?.contains("channelId=c1") == true)
            return json(
                #"{"totalViews":10,"totalLikes":2,"totalComments":1,"totalSubscribers":3,"totalVideos":4,"avgViewsPerVideo":2.5,"engagementRate":30,"topVideo":null}"#
            )
        }.analyticsSummary(channelID: "c1")
        #expect(summary.averageViewsPerVideo == 2.5)
        let days = try await service { request in
            #expect(request.url?.path() == "/api/analytics/metrics")
            let query = request.url?.query() ?? ""
            #expect(query.contains("dateFrom=") && query.contains("dateTo=") && query.contains("channelId=c1"))
            return json(
                #"[{"date":"2026-11-08","views":5,"likes":1,"comments":0,"shares":0,"subscribers":1,"watchTime":600}]"#)
        }.dailyMetrics(channelID: "c1", period: period)
        #expect(days.first?.watchTime == 600)
        let curve = try await service { request in
            #expect(request.url?.path() == "/api/analytics/videos/v1/retention")
            return json(#"{"starts":3,"points":null}"#)
        }.retention(videoID: "v1", period: period)
        #expect(curve.points == nil)
    }

    // MARK: Renditions

    @Test func renditionsDeclarePutCompleteAndCancel() async throws {
        let files = [StagedFile(path: "360p/index.m3u8", bytes: 3), StagedFile(path: "360p/seg_00001.m4s", bytes: 4)]
        let staging = try await service { request in
            #expect(request.url?.path() == "/api/videos/v1/renditions")
            let body = object(request)
            #expect(body["rungs"] as? [String] == ["360p"])
            #expect((body["files"] as? [[String: Any]])?.last?["bytes"] as? Int == 4)
            #expect(body["encoder"] as? String == "Studio for Mac 1.0")
            return json(
                #"{"success":true,"data":{"stagingId":"s1","status":"uploading","rungs":["360p"],"files":2,"bytes":7,"createdAt":"x","maxFileBytes":33554432}}"#,
                status: 201)
        }.createRenditions(videoID: "v1", rungs: ["360p"], files: files, encoder: "Studio for Mac 1.0", channelID: "c1")
        #expect(staging == RenditionStaging(stagingID: "s1", maxFileBytes: 33_554_432))
        try await service { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path() == "/api/videos/v1/renditions/s1/files/360p/seg_00001.m4s")
            #expect(request.value(forHTTPHeaderField: "Content-Length") == "4")
            return (204, [:], Data())
        }.putRenditionFile(videoID: "v1", stagingID: "s1", file: files[1], bytes: Data([1, 2, 3, 4]), channelID: "c1")
        await #expect(throws: CoreError.invalid("size_mismatch")) {
            try await service { _ in (204, [:], Data()) }
                .putRenditionFile(videoID: "v1", stagingID: "s1", file: files[1], bytes: Data([1]), channelID: nil)
        }
        await #expect(throws: CoreError.conflict("files_missing", missing: ["360p/index.m3u8"])) {
            try await service { _ in
                json(#"{"success":false,"error":"files_missing","missing":["360p/index.m3u8"]}"#, status: 409)
            }.completeRenditions(videoID: "v1", stagingID: "s1", channelID: nil)
        }
        try await service { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path() == "/api/videos/v1/renditions/s1")
            return json(#"{"success":true}"#)
        }.cancelRenditions(videoID: "v1", stagingID: "s1", channelID: nil)
    }

    @Test func flattenedTimelineDecodesCoreShape() throws {
        let timeline = try FlattenedTimeline.decode(
            """
            {"durationMs":4000,"tracks":[{"id":"v1","kind":"video","muted":false,"clips":[
              {"clipId":"a","sourceId":"s","path":"/tmp/a.mov","inMs":1000,"outMs":3000,"timelineStartMs":0,"speed":2,"volume":0.5}
            ]}]}
            """)
        #expect(timeline.tracks.first?.clips.first?.timelineDurationMs == 1000)
        #expect(throws: CoreError.decoding) { try FlattenedTimeline.decode("{}") }
    }
}

/// A value tests set from a `@Sendable` handler.
final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

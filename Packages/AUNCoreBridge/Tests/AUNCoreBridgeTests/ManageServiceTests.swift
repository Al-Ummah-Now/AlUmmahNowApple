import Foundation
import Testing

@testable import AUNCoreBridge

struct ManageServiceTests {
    private let base = URL(string: "https://videos.api.qa.alummahnow.net")!

    private func service(_ handler: @escaping StubURLProtocol.Handler) -> NativeStudioService {
        NativeStudioService(
            baseURL: base, accounts: FixtureAccountService(signedIn: [FixtureAccountService.creator]),
            session: StubURLProtocol.session(handler: handler))
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    @Test func contentSendsTheFiltersAndDecodesStudioFields() async throws {
        let body = """
            {"success":true,"result":{"items":[{"id":"v1","title":"T","titleLocalized":{"ar":"ع"},"isPublic":false,
            "isDraft":true,"tags":"a, b","views":3,"likesCount":2,"commentsCount":1,"duration":61.5,
            "dateCreated":"2026-11-01T10:00:00.000Z","studioStatus":"drafts","failureKind":null}],"cursor":""}}
            """
        let page = try await service { request in
            #expect(request.url?.path() == "/api/channels/c1/content")
            #expect(request.value(forHTTPHeaderField: "channelId") == "c1")
            let items = query(request)
            #expect(items["status"] == "drafts")
            #expect(items["q"] == "tafsir")
            #expect(items["sort"] == "views")
            #expect(items["visibility"] == nil)
            #expect(items["cursor"] == nil)
            return (200, [:], Data(body.utf8))
        }.content(channelID: "c1", query: ContentQuery(status: .drafts, text: " tafsir ", sort: .views), cursor: "")
        #expect(page.cursor == nil)
        let video = try #require(page.items.first)
        #expect(video.tags == ["a", "b"])
        #expect(video.studioStatus == .drafts)
        #expect(video.displayTitle(.ar) == "ع")
        #expect(video.likes == 2)
        #expect(video.dateCreated != nil)
    }

    @Test func bulkRoutesSendTheChannelHeaderLikeTheWebAndReadPerVideoResults() async throws {
        let reply =
            #"{"success":true,"results":[{"videoId":"a","success":true},{"videoId":"b","success":false,"error":"Forbidden"}],"summary":{"total":2,"succeeded":1,"failed":1}}"#
        let paths = ["/api/videos/bulk-update", "/api/videos/bulk-delete", "/api/videos/bulk-restore", "/api/videos/bulk-purge"]
        final class Paths: @unchecked Sendable {
            var seen: [String] = []
        }
        let recorded = Paths()
        let lock = NSLock()
        let studio = service { request in
            // As the web: bulk-delete (where it is required) and bulk-update send it; restore and purge don't.
            let path = request.url!.path()
            let expected = ["/api/videos/bulk-delete", "/api/videos/bulk-update"].contains(path) ? "c1" : nil
            #expect(request.value(forHTTPHeaderField: "channelId") == expected, "\(path)")
            lock.withLock { recorded.seen.append(request.url!.path()) }
            if request.url!.path() == "/api/videos/bulk-update" {
                let body = try JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                let changes = body?["changes"] as? [String: Any]
                #expect(changes?["isPublic"] as? Bool == false)
                #expect(changes?["addTags"] as? [String] == ["x"])
                #expect(changes?["category"] == nil)
            }
            return (200, [:], Data(reply.utf8))
        }
        let update = try await studio.bulkUpdate(["a", "b"], BulkChanges(isPublic: false, addTags: ["x"]), channelID: "c1")
        #expect(update.succeeded == 1)
        #expect(update.failed.map(\.videoID) == ["b"])
        _ = try await studio.deleteVideos(["a"], channelID: "c1")
        _ = try await studio.restoreVideos(["a"])
        _ = try await studio.purgeVideos(["a"])
        #expect(lock.withLock { recorded.seen } == paths)
    }

    @Test func bulkScheduleRefusalByPlanIsA402() async {
        await #expect(throws: CoreError.http(status: 402)) {
            try await service { _ in
                (402, [:], Data(#"{"success":false,"error":"upgrade_required","entitlement":"studio.bulkSchedule"}"#.utf8))
            }.bulkSchedule(["a"], startAt: Date(), intervalMinutes: 60, timeZone: .current)
        }
    }

    @Test func deletedVideosDecodeTheirPurgeDate() async throws {
        let body = """
            {"success":true,"result":{"items":[{"id":"v1","title":"Gone","deletedAt":"2026-11-10T10:00:00.000Z",
            "deletedBy":"u","purgeAfter":"2026-12-10T10:00:00.000Z","status":"queued"}],"cursor":null}}
            """
        let page = try await service { request in
            #expect(request.url?.path() == "/api/channels/c1/content/deleted")
            return (200, [:], Data(body.utf8))
        }.deletedVideos(channelID: "c1", cursor: nil)
        #expect(page.items.first?.status == .queued)
        #expect(page.items.first?.purgeAfter != nil)
        #expect(page.items.first?.canRestore == true)
        #expect(page.cursor == nil)
    }

    @Test func channelStatsDecodeTheRawObject() async throws {
        let body = """
            {"channelId":"c1","totalViews":120,"totalVideos":4,"totalSubscribers":9,"totalLikes":7,"totalComments":2,
             "avgViewsPerVideo":30,"avgEngagementRate":7.5,
             "topPerformingVideos":[{"videoId":"v1","title":"A","views":80,"likes":5,"dislikes":0,"comments":1,"shares":0,
               "watchTime":3600,"avgViewDuration":45,"clickThroughRate":0,"engagementRate":7.5,"dateCreated":"2026-11-01"}],
             "recentMetrics":[{"date":"2026-11-09","views":60,"likes":3,"comments":1,"shares":0,"subscribers":2,"watchTime":1800},
                              {"date":"2026-11-10","views":60,"likes":4,"comments":1,"shares":0,"subscribers":1,"watchTime":1800}],
             "traffic":{"totalViews":120,"sources":{},"externalHosts":[]}}
            """
        let stats = try await service { request in
            #expect(request.url?.path() == "/api/analytics/channels/c1")
            #expect(query(request)["dateFrom"]?.hasSuffix("Z") == true)
            return (200, [:], Data(body.utf8))
        }.channelStats(channelID: "c1", period: AnalyticsRange.days28.periods().current)
        #expect(stats.totalViews == 120)
        #expect(stats.topVideos.first?.averageViewDuration == 45)
        #expect(stats.watchTime == 3600)
        // Totals are lifetime; the period comes from the daily series.
        #expect(stats.periodViews == 120)
        #expect(stats.periodSubscribers == 3)
        #expect(stats.daily.first?.day != nil)
        #expect(periodChange(120, 100) == 0.2)
        #expect(periodChange(5, 0) == nil)
    }
}

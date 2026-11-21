import Foundation
import Testing

@testable import AUNCoreBridge

/// The Viewer and Studio fixtures describe one channel: the same videos, titles, thumbnails and numbers.
struct FixtureLibraryTests {
    private let studio = FixtureStudioService()

    @Test func theViewerShowsExactlyStudiosPublishedPublicVideos() async throws {
        let published = try await studio.content(
            channelID: "fixture-channel", query: ContentQuery(status: .published), cursor: nil
        ).items.filter(\.isPublic)
        let viewer = FixtureCatalogService.videos
        #expect(viewer.count == published.count)
        for video in viewer {
            let match = try #require(published.first { $0.titleLocalized == video.titleLocalized })
            #expect(match.views == video.views)
            #expect(match.thumbnailURL == video.thumbnailURL)
            #expect(match.durationSeconds == video.durationSeconds)
            #expect(video.displayChannelName(.ar) == "الأمة الآن")
            #expect(video.displayChannelName(.en) == "Al Ummah Now")
        }
    }

    @Test func draftsScheduledAndProcessingNeverReachTheViewer() async throws {
        let hidden = FixtureLibrary.items.filter { !$0.isWatchable }
        #expect(Set(hidden.map(\.status)) == [.drafts, .scheduled, .processing])
        let rails = try await FixtureCatalogService().homeRails(limit: 12)
        let titles = Set(rails.flatMap(\.videos).map(\.title))
        for item in hidden { #expect(!titles.contains(item.titleEN)) }
        #expect(rails[0].videos.map(\.views) == rails[0].videos.map(\.views).sorted(by: >))
    }

    @Test func everyThumbnailIsBundled() {
        for item in FixtureLibrary.items {
            let url = try? #require(FixtureLibrary.thumbnail(item.thumb))
            #expect(url.map { FileManager.default.fileExists(atPath: $0.path) } == true, "\(item.thumb)")
        }
    }

    @Test(arguments: AnalyticsRange.allCases)
    func lifetimeAndTopVideosAgreeWithThePeriod(_ range: AnalyticsRange) async throws {
        let periods = range.periods()
        let stats = try await studio.channelStats(channelID: "fixture-channel", period: periods.current)
        let viewerTotal = FixtureCatalogService.videos.reduce(0) { $0 + $1.views }
        #expect(stats.daily.count == range.rawValue)
        #expect(stats.totalViews == viewerTotal)
        #expect(stats.totalViews >= stats.periodViews)
        #expect(stats.totalSubscribers >= stats.periodSubscribers)
        #expect(stats.topVideos.reduce(0) { $0 + $1.periodViews } <= stats.periodViews)
        for video in stats.topVideos { #expect(video.periodViews <= video.views, "\(video.title)") }
        #expect(stats.topVideos.map(\.periodViews) == stats.topVideos.map(\.periodViews).sorted(by: >))
    }

    @Test func dailyViewsHaveAWeeklyRhythmAndNoise() async throws {
        let stats = try await studio.channelStats(channelID: "fixture-channel", period: AnalyticsRange.days90.periods().current)
        let views = stats.daily.map(\.views)
        #expect(Set(views).count > views.count * 9 / 10, "no repeated flat values")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let fridays = stats.daily.filter { $0.day.map { calendar.component(.weekday, from: $0) } == 6 }.map(\.views)
        let average = Double(views.reduce(0, +)) / Double(views.count)
        #expect(Double(fridays.reduce(0, +)) / Double(fridays.count) > average * 1.2)
    }
}

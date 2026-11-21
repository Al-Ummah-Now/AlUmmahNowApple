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

    @Test(arguments: [false, true])
    func everyThumbnailIsBundledInBothLanguages(_ arabic: Bool) {
        for item in FixtureLibrary.items {
            let url = try? #require(FixtureLibrary.thumbnail(item.thumb, arabic: arabic))
            #expect(url.map { FileManager.default.fileExists(atPath: $0.path) } == true, "\(item.thumb)")
        }
    }

    /// The card is text, so it follows the page: English pages get the English card, Arabic pages the Arabic one.
    @Test func titleCardsFollowTheLanguage() {
        let english = FixtureCatalogService.videos(arabic: false).compactMap(\.thumbnailURL?.lastPathComponent)
        let arabic = FixtureCatalogService.videos(arabic: true).compactMap(\.thumbnailURL?.lastPathComponent)
        #expect(!english.isEmpty && english.allSatisfy { $0.hasSuffix("-en.jpg") })
        #expect(arabic.count == english.count && arabic.allSatisfy { !$0.hasSuffix("-en.jpg") })
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

    @Test func dailyViewsHaveNoiseAndOnlyAGentleWeeklyRhythm() async throws {
        let stats = try await studio.channelStats(channelID: "fixture-channel", period: AnalyticsRange.days90.periods().current)
        let views = stats.daily.map(\.views)
        #expect(Set(views).count > views.count * 9 / 10, "no repeated flat values")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let fridays = stats.daily.filter { $0.day.map { calendar.component(.weekday, from: $0) } == 6 }.map(\.views)
        let average = Double(views.reduce(0, +)) / Double(views.count)
        #expect(Double(fridays.reduce(0, +)) / Double(fridays.count) < average * 1.1, "no Friday spikes a week apart")
    }

    /// Every upload but the one still processing is older than the 28-day window, so no video's 28-day views can pass
    /// its lifetime views and the chart has no launch spike without an upload behind it. The gaps are irregular.
    @Test func uploadsPredateTheWindowAtIrregularGaps() {
        let recent = FixtureLibrary.items.filter { $0.age <= 28 }
        #expect(recent.map(\.status) == [.processing])
        #expect(recent.allSatisfy { $0.age == 0 && $0.views == 0 })
        let ages = FixtureLibrary.items.filter { $0.status == .published }.map(\.age).sorted()
        let gaps = zip(ages.dropFirst(), ages).map { $0 - $1 }
        #expect(Set(gaps).count == gaps.count, "\(gaps)")
        #expect(gaps.allSatisfy { $0 % 7 != 0 }, "\(gaps)")
    }

    /// The 28-day chart, on any day it is opened: no day stands far above the rest.
    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 13, 30])
    func the28DayChartHasNoSpikes(_ shift: Int) {
        let now = Date().addingTimeInterval(Double(shift) * 86_400)
        let today = FixtureLibrary.today(now)
        let period = DateInterval(start: today.addingTimeInterval(-27 * 86_400), end: today.addingTimeInterval(86_399))
        let published = FixtureLibrary.items.filter { $0.status == .published }
        let views = FixtureLibrary.daily(published, period, now: now).map(\.views).sorted()
        #expect(views.count == 28)
        #expect(Double(views.last ?? 0) < Double(views[views.count / 2]) * 1.3, "\(views)")
    }

    /// No title is another's with a letter more or less ("Ramadan reminder" / "Ramadan reminders").
    @Test(arguments: [AppLanguage.en, .ar])
    func titlesAreClearlyDifferent(_ language: AppLanguage) {
        let titles = FixtureLibrary.items.map { language == .ar ? $0.title.ar ?? "" : $0.titleEN }
        for (index, title) in titles.enumerated() {
            for other in titles[(index + 1)...] {
                #expect(!title.hasPrefix(other) && !other.hasPrefix(title), "\(title) / \(other)")
            }
        }
    }

    @Test func heldCommentsFollowTheAppLanguage() {
        let latin = /[A-Za-z0-9]/
        for comment in FixtureStudioService.heldComments(arabic: true) {
            #expect(comment.authorName.firstMatch(of: latin) == nil, "\(comment.authorName)")
            #expect(comment.text.firstMatch(of: latin) == nil, "\(comment.text)")
        }
        #expect(FixtureStudioService.heldComments(arabic: false).map(\.authorName) == ["Maryam Haddad", "Omar Saleh"])
    }

    @Test func theLanguageRuleMatchesAppSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "fixture-language-\(UUID())"))
        #expect(FixtureLibrary.prefersArabic(defaults: defaults, preferredLanguages: ["fr", "ar-SA", "en"]))
        #expect(!FixtureLibrary.prefersArabic(defaults: defaults, preferredLanguages: ["en-US", "ar"]))
        #expect(!FixtureLibrary.prefersArabic(defaults: defaults, preferredLanguages: ["fr"]))
        defaults.set("ar", forKey: "AUNLanguage")
        #expect(FixtureLibrary.prefersArabic(defaults: defaults, preferredLanguages: ["en"]))
    }
}

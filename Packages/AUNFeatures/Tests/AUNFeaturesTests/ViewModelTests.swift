import AUNCoreBridge
import Foundation
import Testing

@testable import AUNFeatures

private struct FailingCatalog: CatalogServicing {
    func homeRails(limit: Int) async throws -> [HomeRail] { throw CoreError.http(status: 500) }
    func video(id: String) async throws -> Video { throw CoreError.notFound }
    func subtitles(videoID: String) async throws -> [SubtitleTrack] { [] }
    func chapters(videoID: String) async throws -> [Chapter] { [] }
    func subtitleText(url: URL) async throws -> String { "" }
}

private struct ProcessingCatalog: CatalogServicing {
    func homeRails(limit: Int) async throws -> [HomeRail] { [] }
    func video(id: String) async throws -> Video { Video(id: id, title: "T", uploadStatus: "processing") }
    func subtitles(videoID: String) async throws -> [SubtitleTrack] { throw CoreError.http(status: 500) }
    func chapters(videoID: String) async throws -> [Chapter] { throw CoreError.http(status: 500) }
    func subtitleText(url: URL) async throws -> String { "" }
}

private struct LiveCatalog: CatalogServicing {
    func homeRails(limit: Int) async throws -> [HomeRail] { [] }
    func video(id: String) async throws -> Video {
        Video(id: id, title: "T", playURL: URL(string: "https://media.test/live.m3u8"), isLive: true)
    }
    func subtitles(videoID: String) async throws -> [SubtitleTrack] { [] }
    func chapters(videoID: String) async throws -> [Chapter] { [] }
    func subtitleText(url: URL) async throws -> String { "" }
}

@MainActor @Suite struct ViewModelTests {
    @Test func homeLoadsRails() async {
        let model = HomeViewModel(catalog: FixtureCatalogService())
        await model.load()
        guard case .loaded(let rails) = model.state else {
            Issue.record("expected rails")
            return
        }
        #expect(rails.map(\.kind) == [.trending, .recent])
    }

    @Test func homeReportsFailure() async {
        let model = HomeViewModel(catalog: FailingCatalog())
        await model.load()
        guard case .failed = model.state else {
            Issue.record("expected failure")
            return
        }
    }

    @Test func watchPassesLocalizedTitleAndTracksToPlayer() async {
        let model = WatchViewModel(videoID: "fixture-1", catalog: FixtureCatalogService())
        await model.load(language: .ar, autoplay: false)
        #expect(model.player.item?.title == "مقدمة في التفسير، الجزء ١")
        #expect(model.player.item?.subtitles.count == 2)
        #expect(model.player.item?.chapters.count == 2)
        #expect(model.player.isPlaying == false)
        model.player.stop()
    }

    @Test func onlyAVideoThatIsNotLiveKeepsItsPosition() async {
        let video = WatchViewModel(videoID: "fixture-1", catalog: FixtureCatalogService())
        await video.load(language: .en, autoplay: false)
        #expect(video.player.item?.resumeID == "fixture-1")
        video.player.stop()

        let live = WatchViewModel(videoID: "live-1", catalog: LiveCatalog())
        await live.load(language: .en, autoplay: false)
        #expect(live.player.item != nil)
        #expect(live.player.item?.resumeID == nil)
        live.player.stop()
    }

    @Test func unfinishedVideoDoesNotStartPlayer() async {
        let model = WatchViewModel(videoID: "x", catalog: ProcessingCatalog())
        await model.load(language: .en)
        guard case .loaded(let content) = model.state else {
            Issue.record("expected content even when extras fail")
            return
        }
        #expect(content.chapters.isEmpty)
        #expect(model.player.item == nil)
    }

    @Test func bootstrapUsesFixturesOnlyWhenAsked() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        #expect(ViewerBootstrap.makeCore(defaults: defaults, info: nil).catalog is NativeCatalogService)
        defaults.set(true, forKey: "AUNUseFixtures")
        #expect(ViewerBootstrap.makeCore(defaults: defaults, info: nil).catalog is FixtureCatalogService)
    }
}

#if os(macOS)
    import SwiftUI

    @Test func arrowKeysFollowReadingDirection() {
        #expect(SkipKey.delta(isRightArrow: true, direction: .leftToRight) == 10)
        #expect(SkipKey.delta(isRightArrow: true, direction: .rightToLeft) == -10)
        #expect(SkipKey.delta(isRightArrow: false, direction: .rightToLeft) == 10)
    }
#endif

struct ViewerLinksTests {
    @Test func videosAndShortsOpenTheWatchPageOtherLinksOpenHome() {
        #expect(ViewerLinks.destination(for: URL(string: "https://videos.alummahnow.net/ar/video/v1")!) == .video("v1"))
        #expect(ViewerLinks.destination(for: URL(string: "https://videos.qa.alummahnow.net/shorts/s1")!) == .video("s1"))
        #expect(ViewerLinks.destination(for: URL(string: "https://videos.alummahnow.net/en/live/l1")!) == .live("l1"))
        #expect(ViewerLinks.destination(for: URL(string: "https://videos.alummahnow.net/en/@main")!) == nil)
        #expect(ViewerLinks.destination(for: URL(string: "https://videos.alummahnow.net/en/studio/c1")!) == nil)
        #expect(ViewerLinks.destination(for: URL(string: "https://example.com/en/video/v1")!) == nil)
    }
}

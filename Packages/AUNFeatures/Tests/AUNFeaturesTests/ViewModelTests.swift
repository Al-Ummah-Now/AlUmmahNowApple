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
        #expect(ViewerLinks.videoID(for: URL(string: "https://videos.alummahnow.net/ar/video/v1")!) == "v1")
        #expect(ViewerLinks.videoID(for: URL(string: "https://videos.qa.alummahnow.net/shorts/s1")!) == "s1")
        #expect(ViewerLinks.liveStreamID(for: URL(string: "https://videos.alummahnow.net/en/live/ls1")!) == "ls1")
        #expect(ViewerLinks.liveStreamID(for: URL(string: "https://videos.alummahnow.net/ar/live/ls2")!) == "ls2")
        #expect(ViewerLinks.videoID(for: URL(string: "https://videos.alummahnow.net/en/@main")!) == nil)
        #expect(ViewerLinks.videoID(for: URL(string: "https://videos.alummahnow.net/en/studio/c1")!) == nil)
        #expect(ViewerLinks.videoID(for: URL(string: "https://example.com/en/video/v1")!) == nil)
    }
}

@MainActor @Suite struct LiveWatchViewModelTests {
    @Test func loadsLiveStreamBeatsViewerAndManagesChatAndReminders() async {
        let model = LiveWatchViewModel(streamID: "fixture-live-1", catalog: FixtureCatalogService())
        await model.load(language: .en, autoplay: false)
        guard case .loaded(let content) = model.state else {
            Issue.record("expected loaded live content")
            return
        }
        #expect(content.mode == .live)
        #expect(content.stream.title == "Friday Khutbah Live")
        #expect(content.state.eventType == .jumuah)
        #expect(model.viewers == 42)
        #expect(model.player.item?.isLiveStream == true)
        #expect(model.messages.count == 2)
        #expect(model.pinnedMessage?.id == "m2")

        // Stage-1 fast filter rejects links from non-moderator viewers
        model.draft = "Check https://spam.invalid"
        await model.sendChat()
        #expect(model.chatError == "urlBlocked")

        // Sending a clean message appends it and clears the draft
        model.draft = "JazakAllahu khairan"
        await model.sendChat()
        #expect(model.chatError == nil)
        #expect(model.draft.isEmpty)
        #expect(model.messages.last?.text == "JazakAllahu khairan")

        model.stop()
    }

    @Test func loadsScheduledPremiereAndTogglesReminder() async {
        let model = LiveWatchViewModel(streamID: "fixture-premiere-1", catalog: FixtureCatalogService())
        await model.load(language: .ar, autoplay: false)
        guard case .loaded(let content) = model.state else {
            Issue.record("expected loaded premiere content")
            return
        }
        #expect(content.mode == .soon)
        #expect(content.state.kind == .premiere)
        #expect(content.state.eventType == .halqa)
        #expect(model.reminder.viewerSubscribed == false)

        await model.toggleReminder()
        #expect(model.reminder.viewerSubscribed == true)
        #expect(model.reminder.count == 13)
        model.stop()
    }
}

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
        #expect(model.player.item?.title == "المحاضرة 1: مقدمة في التفسير")
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

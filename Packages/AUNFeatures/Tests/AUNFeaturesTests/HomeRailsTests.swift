import AUNCoreBridge
import Testing

@testable import AUNFeatures

struct HomeRailsTests {
    @Test func theHeroIsNotRepeatedAsTheFirstCard() {
        let videos = FixtureCatalogService.videos
        let rails = [HomeRail(kind: .trending, videos: videos), HomeRail(kind: .recent, videos: videos)]
        #expect(rails.cards(of: rails[0]).map(\.id) == videos.dropFirst().map(\.id))
        #expect(rails.cards(of: rails[1]).map(\.id) == videos.map(\.id))
    }
}

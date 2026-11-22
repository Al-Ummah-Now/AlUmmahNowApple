import Foundation

/// Stable bilingual data for UI tests, snapshots and previews. No network access.
public struct FixtureCatalogService: CatalogServicing {
    /// Playable fixtures stream a short bundled clip instead of an address that never answers, so store screenshots
    /// (`-AUNFixturePlayable YES`) show the player instead of its error. Tests keep the unplayable default.
    private let playable: Bool

    public init(playable: Bool = false) { self.playable = playable }

    /// A few seconds of a still frame (8 KB), bundled with AUNCoreBridge.
    public static var playableClip: URL? { Bundle.module.url(forResource: "fixture-video", withExtension: "mp4") }

    private func served(_ video: Video) -> Video {
        guard playable, let clip = Self.playableClip else { return video }
        var copy = video
        copy.playURL = clip
        return copy
    }

    /// The fixture channel's published public videos (`FixtureLibrary`), most viewed first; the ones Studio holds as
    /// drafts, scheduled or still processing never show here. Title cards follow the app's language.
    public static var videos: [Video] { videos(arabic: FixtureLibrary.prefersArabic()) }

    /// The same videos with title cards in Arabic or English.
    public static func videos(arabic: Bool) -> [Video] {
        let now = Date()
        return FixtureLibrary.watchable.sorted { $0.views > $1.views }.map { item in
            Video(
                id: item.viewerID, title: item.titleEN, titleLocalized: item.title, description: item.summary.en,
                descriptionLocalized: item.summary, thumbnailURL: FixtureLibrary.thumbnail(item.thumb, arabic: arabic),
                playURL: URL(string: "https://fixtures.invalid/\(item.index)/playlist.m3u8"), channelID: "fixture-channel",
                channelName: FixtureLibrary.channelName.en, channelNameLocalized: FixtureLibrary.channelName,
                views: item.views, durationSeconds: item.seconds, category: "quran_tafsir",
                dateCreated: FixtureLibrary.uploaded(item, now: now), availableResolutions: ["240p", "360p"])
        }
    }

    /// Trending: most viewed first. Recently added: newest first.
    public func homeRails(limit: Int) async throws -> [HomeRail] {
        let videos = Self.videos
        let recent = videos.sorted { ($0.dateCreated ?? .distantPast) > ($1.dateCreated ?? .distantPast) }
        return [
            HomeRail(kind: .trending, videos: videos.prefix(limit).map(served)),
            HomeRail(kind: .recent, videos: recent.prefix(limit).map(served)),
        ]
    }

    public func video(id: String) async throws -> Video {
        guard let video = Self.videos.first(where: { $0.id == id }) else { throw CoreError.notFound }
        return served(video)
    }

    public func subtitles(videoID: String) async throws -> [SubtitleTrack] {
        [
            SubtitleTrack(id: "en", language: "en", label: "English", url: Self.subtitleURL, isDefault: true),
            SubtitleTrack(id: "ar", language: "ar", label: "العربية", url: Self.subtitleURL),
        ]
    }

    public func chapters(videoID: String) async throws -> [Chapter] { FixtureLibrary.chapters(viewerID: videoID) }

    public func subtitleText(url: URL) async throws -> String {
        "WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nFixture cue\n"
    }

    private static let subtitleURL = URL(string: "https://fixtures.invalid/subtitles.vtt")!
}

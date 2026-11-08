import Foundation

/// Stable bilingual data for UI tests, snapshots and previews. No network access.
public struct FixtureCatalogService: CatalogServicing {
    public init() {}

    public static let videos: [Video] = (1...8).map { index in
        Video(
            id: "fixture-\(index)",
            title: "Lecture \(index): Introduction to Tafsir",
            titleLocalized: LocalizedText(
                en: "Lecture \(index): Introduction to Tafsir", ar: "المحاضرة \(index): مقدمة في التفسير"),
            description: "An introduction to the sources of tafsir.",
            descriptionLocalized: LocalizedText(
                en: "An introduction to the sources of tafsir.", ar: "مقدمة في مصادر التفسير."),
            playURL: URL(string: "https://fixtures.invalid/\(index)/playlist.m3u8"),
            channelID: "fixture-channel",
            channelName: "Al Ummah Now",
            views: 1200 * index,
            durationSeconds: Double(75 * index),
            category: "quran_tafsir",
            availableResolutions: ["240p", "360p"]
        )
    }

    public func homeRails(limit: Int) async throws -> [HomeRail] {
        [
            HomeRail(kind: .trending, videos: Array(Self.videos.prefix(limit))),
            HomeRail(kind: .recent, videos: Array(Self.videos.reversed().prefix(limit))),
        ]
    }

    public func video(id: String) async throws -> Video {
        guard let video = Self.videos.first(where: { $0.id == id }) else { throw CoreError.notFound }
        return video
    }

    public func subtitles(videoID: String) async throws -> [SubtitleTrack] {
        [
            SubtitleTrack(id: "en", language: "en", label: "English", url: Self.subtitleURL, isDefault: true),
            SubtitleTrack(id: "ar", language: "ar", label: "العربية", url: Self.subtitleURL),
        ]
    }

    public func chapters(videoID: String) async throws -> [Chapter] {
        [
            Chapter(
                id: "c1", startTime: 0, endTime: 30, title: "Introduction",
                titleLocalized: LocalizedText(en: "Introduction", ar: "المقدمة")),
            Chapter(id: "c2", startTime: 30, title: "Sources", titleLocalized: LocalizedText(en: "Sources", ar: "المصادر")),
        ]
    }

    public func subtitleText(url: URL) async throws -> String {
        "WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nFixture cue\n"
    }

    private static let subtitleURL = URL(string: "https://fixtures.invalid/subtitles.vtt")!
}

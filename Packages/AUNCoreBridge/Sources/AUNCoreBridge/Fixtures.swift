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

    public static let videos: [Video] = (1...8).map { index in
        // Arabic fixture titles are written the way an Arabic creator types them, with ٠–٩.
        let arabicIndex = index.formatted(.number.locale(AppLanguage.ar.locale))  // swiftlint:disable:this display_format
        return Video(
            id: "fixture-\(index)",
            title: "Introduction to Tafsir, part \(index)",
            titleLocalized: LocalizedText(
                en: "Introduction to Tafsir, part \(index)", ar: "مقدمة في التفسير، الجزء \(arabicIndex)"),
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
            HomeRail(kind: .trending, videos: Self.videos.prefix(limit).map(served)),
            HomeRail(kind: .recent, videos: Self.videos.reversed().prefix(limit).map(served)),
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

    public static let liveStreamsList: [LiveStream] = [
        LiveStream(
            id: "fixture-live-1", title: "Friday Khutbah Live",
            description: "Weekly live broadcast from the community masjid.",
            status: .live, kind: .live, eventType: .jumuah,
            channelID: "fixture-channel", channelName: "Al Ummah Now",
            playbackURL: URL(string: "https://fixtures.invalid/live/1/playlist.m3u8"),
            currentViewers: 42),
        LiveStream(
            id: "fixture-premiere-1", title: "Ramadan Tafsir Premiere",
            description: "Special premiere with live moderated chat.",
            status: .scheduled, kind: .premiere, premiereVideoID: "fixture-1", eventType: .halqa,
            channelID: "fixture-channel", channelName: "Al Ummah Now",
            scheduledStartTime: Date(timeIntervalSinceNow: 3600),
            playbackURL: URL(string: "https://fixtures.invalid/1/playlist.m3u8")),
    ]

    public func liveStreams(
        status: LiveStreamStatus? = .live, eventType: LiveEventType? = nil, limit: Int = 20
    ) async throws -> [LiveStream] {
        Self.liveStreamsList.filter { stream in
            (status == nil || stream.status == status) && (eventType == nil || stream.eventType == eventType)
        }.prefix(limit).map { stream in
            guard playable, let clip = Self.playableClip else { return stream }
            var copy = stream
            copy.playbackURL = clip
            return copy
        }
    }

    public func liveStream(id: String) async throws -> LiveStream {
        guard let stream = Self.liveStreamsList.first(where: { $0.id == id }) else { throw CoreError.notFound }
        guard playable, let clip = Self.playableClip else { return stream }
        var copy = stream
        copy.playbackURL = clip
        return copy
    }

    public func liveStreamState(id: String) async throws -> LiveStreamState {
        let stream = try await liveStream(id: id)
        return LiveStreamState(
            streamID: stream.id, sessionID: "sess-\(stream.id)", status: stream.status,
            sessionStatus: stream.status == .live ? "live" : "provisioned",
            receiving: stream.status == .live, playbackURL: stream.playbackURL, vodURL: stream.vodURL,
            viewers: stream.currentViewers, kind: stream.kind, premiereVideoID: stream.premiereVideoID,
            eventType: stream.eventType, scheduledStartTime: stream.scheduledStartTime, dvrWindowSeconds: 7200,
            chat: LiveChatSettings(enabled: true, replayEnabled: true, slowModeSeconds: 0, subscribersOnly: false),
            reminders: LiveReminderStatus(enabled: true, count: 12, viewerSubscribed: false))
    }

    public func beatLiveViewer(streamID: String, viewerID: String, leaving: Bool = false) async throws -> Int? {
        leaving ? 41 : 42
    }

    public func liveChatMessages(
        streamID: String, afterID: String? = nil, afterOffsetMs: Int? = nil, toOffsetMs: Int? = nil, limit: Int = 50
    ) async throws -> LiveChatPage {
        let messages = [
            LiveChatMessage(
                id: "m1", streamID: streamID, userID: "u1", authorName: "Ahmad",
                text: "Assalamu alaikum wa rahmatullah", offsetMs: 12_000),
            LiveChatMessage(
                id: "m2", streamID: streamID, userID: "u2", authorName: "Al Ummah Now",
                authorRole: .owner, text: "Welcome to the live stream.", offsetMs: 25_000, isPinned: true),
        ]
        return LiveChatPage(
            messages: messages, pinnedMessage: messages.last,
            settings: LiveChatSettings(enabled: true, replayEnabled: true, pinnedMessage: messages.last),
            canModerate: false)
    }

    public func postLiveChatMessage(streamID: String, text: String) async throws -> LiveChatMessage {
        if let rejected = LiveChatFastFilter.check(text) {
            throw CoreError.invalid(rejected.rawValue)
        }
        return LiveChatMessage(
            id: "m-new", streamID: streamID, userID: "me", authorName: "Viewer", text: text, offsetMs: 30_000)
    }

    public func setLiveReminder(streamID: String, subscribed: Bool) async throws -> LiveReminderStatus {
        LiveReminderStatus(enabled: true, count: subscribed ? 13 : 11, viewerSubscribed: subscribed)
    }

    private static let subtitleURL = URL(string: "https://fixtures.invalid/subtitles.vtt")!
}

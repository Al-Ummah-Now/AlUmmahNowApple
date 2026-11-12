import Foundation

/// Videos that fixture actions change, shared by every copy of one `FixtureStudioService`.
actor FixtureContentStore {
    var videos: [StudioVideo]
    var deleted: [DeletedVideo] = []

    init() {
        let titles: [(String, String, StudioStatus, Bool)] = [
            ("Tafsir of Surah Al-Kahf, part 1", "تفسير سورة الكهف، الجزء الأول", .published, true),
            ("Tafsir of Surah Al-Kahf, part 2", "تفسير سورة الكهف، الجزء الثاني", .published, true),
            ("Friday khutbah: patience", "خطبة الجمعة: الصبر", .published, false),
            ("Seerah lesson 4", "درس السيرة الرابع", .scheduled, false),
            ("Fiqh of fasting (draft)", "فقه الصيام (مسودة)", .drafts, false),
        ]
        videos = titles.enumerated().map { index, item in
            StudioVideo(
                id: "fixture-content-\(index + 1)", title: item.0, titleLocalized: LocalizedText(en: item.0, ar: item.1),
                description: "", channelID: "fixture-channel", isPublic: item.3, isDraft: item.2 == .drafts,
                tags: index < 2 ? ["tafsir"] : [], category: index < 2 ? VideoCategory.quranTafsir.rawValue : nil,
                durationSeconds: Double(600 + index * 120), views: 1500 - index * 200, likes: 40 - index, comments: 5,
                dateCreated: Date(timeIntervalSince1970: 1_794_000_000 - Double(index) * 86_400), studioStatus: item.2,
                scheduledPublishDate: item.2 == .scheduled ? Date(timeIntervalSince1970: 1_800_000_000) : nil)
        }
    }

    func page(_ query: ContentQuery) -> [StudioVideo] {
        let text = query.text.lowercased()
        return videos.filter { video in
            video.studioStatus == query.status
                && (text.isEmpty || video.title.lowercased().contains(text)
                    || (video.titleLocalized?.ar ?? "").contains(query.text))
        }
    }

    func counts() -> ContentCounts {
        Dictionary(grouping: videos, by: { $0.studioStatus ?? .published }).mapValues(\.count)
    }

    func apply(_ ids: [String], _ change: (inout StudioVideo) -> Void) -> BulkResult {
        BulkResult(
            items: ids.map { id in
                guard let index = videos.firstIndex(where: { $0.id == id }) else {
                    return .init(videoID: id, success: false, error: "Not found")
                }
                change(&videos[index])
                return .init(videoID: id, success: true)
            })
    }

    func delete(_ ids: [String]) -> BulkResult {
        let removed = videos.filter { ids.contains($0.id) }
        videos.removeAll { ids.contains($0.id) }
        deleted += removed.map {
            DeletedVideo(id: $0.id, title: $0.title, deletedAt: Date(), purgeAfter: Date().addingTimeInterval(30 * 86_400))
        }
        return BulkResult(items: ids.map { id in .init(videoID: id, success: removed.contains { $0.id == id }) })
    }

    func restore(_ ids: [String], from original: [StudioVideo]) -> BulkResult {
        let back = deleted.filter { ids.contains($0.id) }
        deleted.removeAll { ids.contains($0.id) }
        videos += original.filter { video in back.contains { $0.id == video.id } }
        return BulkResult(items: ids.map { id in .init(videoID: id, success: back.contains { $0.id == id }) })
    }

    func purge(_ ids: [String]) -> BulkResult {
        for index in deleted.indices where ids.contains(deleted[index].id) { deleted[index].status = .queued }
        return BulkResult(items: ids.map { .init(videoID: $0, success: true) })
    }
}

/// Bilingual channels and videos for UI tests, snapshots and previews.
public struct FixtureStudioService: StudioServicing {
    /// The account states UI tests can start in (`-AUNFixtureAccountState`).
    public enum AccountState: String, Sendable { case creator, invitation, pendingDeletion }

    let store = FixtureContentStore()
    private let original = FixtureContentStore()
    let accountState: AccountState

    public init(accountState: AccountState = .creator) { self.accountState = accountState }

    public func creatorAccess() async throws -> CreatorAccess {
        switch accountState {
        case .creator: CreatorAccess(tierName: "Creator")
        case .invitation: CreatorAccess(canUpload: false, canCreateChannel: false)
        case .pendingDeletion: CreatorAccess(canUpload: false, canCreateChannel: false, pendingDeletion: true)
        }
    }

    /// Writes refused the way api-videos refuses them for this account state. Without a tier only uploads are refused.
    func refuseWrites(upload: Bool = false) throws {
        switch accountState {
        case .creator: return
        case .invitation: if upload { throw CoreError.refused(Refusal(code: Refusal.uploadsByInvitation)) }
        case .pendingDeletion: throw CoreError.refused(Refusal(code: Refusal.accountPendingDeletion))
        }
    }

    public static let channels: [StudioChannel] = [
        StudioChannel(
            id: "fixture-channel", name: "Al Ummah Now", nameLocalized: LocalizedText(en: "Al Ummah Now", ar: "الأمة الآن"),
            handle: "alummahnow", isMain: true, role: .owner),
        StudioChannel(
            id: "fixture-channel-2", name: "Tafsir Circle", nameLocalized: LocalizedText(en: "Tafsir Circle", ar: "حلقة التفسير"),
            handle: "tafsir", role: .editor, capabilities: ["video.upload", "video.edit"]),
        StudioChannel(
            id: "fixture-channel-3", name: "Comments desk",
            nameLocalized: LocalizedText(en: "Comments desk", ar: "مكتب التعليقات"),
            role: .moderator, capabilities: ["comment.moderate"]),
    ]

    public func channels() async throws -> [StudioChannel] { Self.channels }

    public static let playlists = [
        StudioPlaylist(
            id: "fixture-playlist-1", title: "Tafsir series",
            titleLocalized: LocalizedText(en: "Tafsir series", ar: "سلسلة التفسير")),
        // An older playlist with no bilingual names: shown as `title` in both languages.
        StudioPlaylist(id: "fixture-playlist-2", title: "Khutbahs", isPublic: false),
    ]

    public func playlists(channelID: String) async throws -> [StudioPlaylist] { Self.playlists }

    public func initiateUpload(_ upload: UploadInitiation, channelID: String) async throws -> UploadTicket {
        try refuseWrites(upload: true)
        return UploadTicket(videoID: "fixture-video-\(UUID().uuidString.prefix(8))", tusSessionID: "fixture", chunkSize: 1 << 20)
    }

    public func resumeUpload(videoID: String, channelID: String) async throws -> UploadTicket {
        UploadTicket(videoID: videoID, tusSessionID: "fixture", chunkSize: 1 << 20)
    }

    public func completeUpload(videoID: String, fileSize: Int64, channelID: String) async throws {}
    public func tusEndpoint() async throws -> (url: URL, headers: [String: String]) {
        (URL(string: "https://fixtures.invalid/api/videos/tus")!, [:])
    }
    public func setLanguage(_ language: VideoLanguage, videoID: String, channelID: String) async throws {}
    public func addToPlaylists(_ playlistIDs: [String], videoID: String, orderKey: String, channelID: String) async throws {}
    public func schedule(videoID: String, at date: Date, timeZone: TimeZone, channelID: String) async throws {}

    public func content(channelID: String, query: ContentQuery, cursor: String?) async throws -> ContentPage {
        ContentPage(items: await store.page(query), cursor: nil)
    }

    public func contentCounts(channelID: String) async throws -> ContentCounts { await store.counts() }

    public func updateVideo(_ id: String, _ edit: VideoEdit, channelID: String) async throws {
        try refuseWrites()
        _ = await store.apply([id]) { video in
            if let title = edit.title {
                video.title = title
                video.titleLocalized = nil
            }
            if let description = edit.description { video.description = description }
            if let isPublic = edit.isPublic { video.isPublic = isPublic }
            if let category = edit.category { video.category = category }
            if let tags = edit.tags { video.tags = tags }
            if let language = edit.language { video.language = language }
        }
    }

    public func deleteVideos(_ ids: [String], channelID: String) async throws -> BulkResult {
        try refuseWrites()
        return await store.delete(ids)
    }

    public func bulkUpdate(_ ids: [String], _ changes: BulkChanges, channelID: String) async throws -> BulkResult {
        try refuseWrites()
        return await store.apply(ids) { video in
            if let isPublic = changes.isPublic { video.isPublic = isPublic }
            if let category = changes.category { video.category = category }
            video.tags = (video.tags + (changes.addTags ?? [])).filter { !(changes.removeTags ?? []).contains($0) }
        }
    }

    public func bulkSchedule(_ ids: [String], startAt: Date, intervalMinutes: Int, timeZone: TimeZone) async throws
        -> BulkResult
    {
        await store.apply(ids) { video in
            video.studioStatus = .scheduled
            video.scheduledPublishDate = startAt
        }
    }

    public func addToPlaylist(_ playlistID: String, videoIDs: [String], channelID: String) async throws {}

    public func deletedVideos(channelID: String, cursor: String?) async throws -> (items: [DeletedVideo], cursor: String?) {
        (await store.deleted, nil)
    }

    public func restoreVideos(_ ids: [String]) async throws -> BulkResult {
        await store.restore(ids, from: await original.videos)
    }

    public func purgeVideos(_ ids: [String]) async throws -> BulkResult { await store.purge(ids) }

    public func channelStats(channelID: String, period: DateInterval) async throws -> ChannelStats {
        let daily = Self.fixtureDays(period)
        let videos = await store.videos.filter { $0.studioStatus == .published }
        return ChannelStats(
            totalViews: daily.reduce(0) { $0 + $1.views }, totalVideos: videos.count, totalSubscribers: 120, totalLikes: 90,
            totalComments: 25, engagementRate: 4.2,
            topVideos: videos.map {
                VideoStats(videoID: $0.id, title: $0.title, views: $0.views / 4, watchTime: 7200, averageViewDuration: 310)
            }, daily: daily)
    }

    public func videoStats(videoID: String, period: DateInterval) async throws -> VideoStats {
        let video = await store.videos.first { $0.id == videoID }
        return VideoStats(
            videoID: videoID, title: video?.title ?? "", views: (video?.views ?? 0) / 4, likes: 12, comments: 3, shares: 2,
            watchTime: 7200, averageViewDuration: 310, engagementRate: 5.1, rangeViews: (video?.views ?? 0) / 8,
            rangeLikes: 6, rangeComments: 2, daily: Self.fixtureDays(period))
    }

    /// One UTC day per day of `period`, both ends counted, as the API answers.
    static func fixtureDays(_ period: DateInterval) -> [DailyMetric] {
        let days = max(1, Int((period.duration / 86_400).rounded(.up)))
        return (0..<min(days, 28)).map { day in
            DailyMetric(
                date: period.start.addingTimeInterval(Double(day) * 86_400).ISO8601Format().prefix(10).description,
                views: 40 + (day * 7) % 30, likes: 3, comments: 1, subscribers: day % 3, watchTime: Double(3600 + day * 120))
        }
    }
}

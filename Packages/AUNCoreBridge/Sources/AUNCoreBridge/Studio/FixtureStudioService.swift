import Foundation

/// Videos that fixture actions change, shared by every copy of one `FixtureStudioService`.
actor FixtureContentStore {
    var videos: [StudioVideo]
    var deleted: [DeletedVideo] = []

    /// Every video of the fixture channel (`FixtureLibrary`), as the Viewer shows the published public ones.
    init() {
        let now = Date()
        videos = FixtureLibrary.items.map { item in
            StudioVideo(
                id: item.studioID, title: item.titleEN, titleLocalized: item.title, description: item.summary.en ?? "",
                descriptionLocalized: item.summary, thumbnailURL: FixtureLibrary.thumbnail(item.thumb),
                channelID: "fixture-channel", isPublic: item.isPublic, isDraft: item.status == .drafts,
                tags: item.thumb.hasPrefix("kahf") || item.thumb == "tafsir" ? ["tafsir"] : [],
                category: VideoCategory.quranTafsir.rawValue, durationSeconds: item.seconds, views: item.views,
                likes: item.likes, comments: item.comments, dateCreated: FixtureLibrary.uploaded(item, now: now),
                uploadStatus: item.status == .processing ? "processing" : "ready", studioStatus: item.status,
                scheduledPublishDate: item.status == .scheduled
                    ? FixtureLibrary.today(now).addingTimeInterval(4 * 86_400 + 15 * 3600) : nil)
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
    let media = FixtureMediaStore()
    private let original = FixtureContentStore()
    let accountState: AccountState
    /// Feature keys switched off for UI tests (`-AUNFixtureFeaturesOff upload,analytics`): `UserFeature` raw values, and
    /// `analytics`, whose routes then answer 404 `feature_off`.
    let featuresOff: Set<String>

    public init(accountState: AccountState = .creator, featuresOff: Set<String> = []) {
        self.accountState = accountState
        self.featuresOff = featuresOff
    }

    /// Every feature on for a creator; without a creator tier, uploads and channel creation are off.
    public func features(channelID: String?) async throws -> UserFeatures {
        var features = UserFeatures.all
        if accountState == .invitation {
            features = features.with(.upload, false).with(.createChannel, false)
        }
        for key in featuresOff { if let feature = UserFeature(rawValue: key) { features = features.with(feature, false) } }
        return features
    }

    /// Two held comments in the app's language, as the server resolves display names per locale.
    public static var heldComments: [HeldComment] { heldComments(arabic: FixtureLibrary.prefersArabic()) }

    static func heldComments(arabic: Bool) -> [HeldComment] {
        func pick(_ en: String, _ ar: String) -> String { arabic ? ar : en }
        return [
            HeldComment(
                id: "fixture-held-1",
                text: pick("Jazakum Allah khayran, is there a part 3?", "جزاكم الله خيرًا، هل هناك جزء ثالث؟"),
                targetTitle: "Tafsir of Surah Al-Kahf, part 2",
                targetTitleLocalized: LocalizedText(en: "Tafsir of Surah Al-Kahf, part 2", ar: "تفسير سورة الكهف، الجزء الثاني"),
                authorName: pick("Maryam Haddad", "مريم حداد"), createdAt: Date(timeIntervalSince1970: 1_794_010_000)),
            HeldComment(
                id: "fixture-held-2",
                text: pick("Which reference was mentioned at minute ten?", "ما المرجع المذكور في الدقيقة العاشرة؟"),
                targetTitle: "Friday khutbah: patience",
                targetTitleLocalized: LocalizedText(en: "Friday khutbah: patience", ar: "خطبة الجمعة: الصبر"),
                authorName: pick("Omar Saleh", "عمر صالح"), createdAt: Date(timeIntervalSince1970: 1_794_000_000)),
        ]
    }

    /// Two held comments; `-AUNFixtureFeaturesOff comments` makes the route answer `feature_off`.
    public func heldComments(channelID: String, limit: Int) async throws -> HeldComments {
        try refuseIfOff("comments")
        return HeldComments(items: Array(Self.heldComments.prefix(limit)), total: Self.heldComments.count)
    }

    private func refuseIfOff(_ key: String) throws {
        if featuresOff.contains(key) { throw CoreError.featureOff }
    }

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
        try refuseIfOff(UserFeature.bulkSchedule.rawValue)
        return await store.apply(ids) { video in
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

    /// The channel's days from `FixtureLibrary`'s daily model: period totals, top videos and lifetime numbers all come
    /// from it, so they agree (lifetime views are at least any period's, top videos add up to at most the period).
    public func channelStats(channelID: String, period: DateInterval) async throws -> ChannelStats {
        try refuseIfOff("analytics")
        let published = await store.videos.filter { $0.studioStatus == .published }
        let items = FixtureLibrary.items.filter { item in published.contains { $0.id == item.studioID } }
        let daily = FixtureLibrary.daily(items, period)
        let top = items.map { item in Self.stats(item, published.first { $0.id == item.studioID }, period) }
            .filter { $0.periodViews > 0 }.sorted { $0.periodViews > $1.periodViews }
        let views = daily.reduce(0) { $0 + $1.views }
        let engagement = daily.reduce(0) { $0 + $1.likes + $1.comments }
        return ChannelStats(
            totalViews: published.reduce(0) { $0 + $1.views }, totalVideos: published.count,
            totalSubscribers: FixtureLibrary.subscribers, totalLikes: published.reduce(0) { $0 + $1.likes },
            totalComments: published.reduce(0) { $0 + $1.comments },
            engagementRate: views > 0 ? (Double(engagement) / Double(views) * 1000).rounded() / 10 : 0,
            topVideos: Array(top.prefix(5)), daily: daily)
    }

    public func videoStats(videoID: String, period: DateInterval) async throws -> VideoStats {
        try refuseIfOff("analytics")
        let video = await store.videos.first { $0.id == videoID }
        guard let item = FixtureLibrary.items.first(where: { $0.studioID == videoID }) else {
            return VideoStats(videoID: videoID, title: video?.title ?? "", views: video?.views ?? 0)
        }
        return Self.stats(item, video, period)
    }

    /// One video's lifetime and period numbers, with its days.
    static func stats(_ item: FixtureLibrary.Item, _ video: StudioVideo?, _ period: DateInterval) -> VideoStats {
        let daily = FixtureLibrary.daily([item], period)
        let views = daily.reduce(0) { $0 + $1.views }
        let likes = daily.reduce(0) { $0 + $1.likes }
        let comments = daily.reduce(0) { $0 + $1.comments }
        return VideoStats(
            videoID: item.studioID, title: video?.title ?? item.titleEN, views: video?.views ?? item.views,
            likes: item.likes, comments: item.comments, shares: item.views / 400,
            watchTime: daily.reduce(0) { $0 + $1.watchTime }, averageViewDuration: item.seconds * FixtureLibrary.averageWatched,
            engagementRate: views > 0 ? (Double(likes + comments) / Double(views) * 1000).rounded() / 10 : 0,
            thumbnailURL: FixtureLibrary.thumbnail(item.thumb), rangeViews: views, rangeLikes: likes, rangeComments: comments,
            daily: daily, titleLocalized: video?.titleLocalized ?? item.title)
    }
}

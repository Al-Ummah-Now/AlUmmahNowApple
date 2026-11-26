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
            ("Seerah, part 4", "السيرة النبوية، الجزء الرابع", .scheduled, false),
            ("Fiqh of fasting (draft)", "فقه الصيام (مسودة)", .drafts, false),
            ("Seerah, part 5", "السيرة النبوية، الجزء الخامس", .processing, false),
        ]
        videos = titles.enumerated().map { index, item in
            StudioVideo(
                id: "fixture-content-\(index + 1)", title: item.0, titleLocalized: LocalizedText(en: item.0, ar: item.1),
                description: "", channelID: "fixture-channel", isPublic: item.3, isDraft: item.2 == .drafts,
                tags: index < 2 ? ["tafsir"] : [], category: index < 2 ? VideoCategory.quranTafsir.rawValue : nil,
                durationSeconds: Double(600 + index * 120), views: 1500 - index * 200, likes: 40 - index, comments: 5,
                dateCreated: Self.created(index, item.2), studioStatus: item.2,
                scheduledPublishDate: item.2 == .scheduled ? Date(timeIntervalSince1970: 1_800_000_000) : nil)
        }
    }

    /// One day apart, newest first; the video still processing is the latest upload.
    static func created(_ index: Int, _ status: StudioStatus) -> Date {
        Date(timeIntervalSince1970: status == .processing ? 1_794_003_600 : 1_794_000_000 - Double(index) * 86_400)
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

/// Tracks fixture Creator Terms upload refusal and acceptance across `FixtureStudioService` calls.
actor FixtureTermsState {
    var refusedOnce = false
    var acceptedAfterRefusal = false

    private var readsSinceRefusal = 0

    /// `lateRead`: nothing can be read until the second read after an upload was refused.
    func canRead() -> Bool {
        guard refusedOnce else { return false }
        readsSinceRefusal += 1
        return readsSinceRefusal > 1
    }

    func markRefused() { refusedOnce = true }
    func markAccepted() { acceptedAfterRefusal = true }
}

private actor FixtureHeldCommentStore {
    private var moderated: [String: Set<String>] = [:]
    private var reports: [String: Set<CommentReportReason>] = [:]

    func held(in channelID: String) -> [HeldComment] {
        FixtureStudioService.heldComments.filter { moderated[channelID]?.contains($0.id) != true }
    }

    func moderate(_ comment: HeldComment, in channelID: String) {
        moderated[channelID, default: []].insert(comment.id)
    }

    func report(_ id: String, reason: CommentReportReason) throws {
        let previous = reports[id, default: []]
        if previous.contains(.childSafety) || (!previous.isEmpty && reason != .childSafety) {
            throw CoreError.conflict("You have already reported this content")
        }
        reports[id, default: []].insert(reason)
    }
}

/// Bilingual channels and videos for UI tests, snapshots and previews.
public struct FixtureStudioService: StudioServicing {
    /// The account states UI tests can start in (`-AUNFixtureAccountState`).
    public enum AccountState: String, Sendable { case creator, invitation, pendingDeletion }
    /// Creator Terms fixture behaviour for UI tests (`-AUNFixtureTermsMode`).
    public enum TermsMode: String, Sendable {
        case accepted, required, failed, acceptError, acceptSlow, acceptVersionChanged, refuseUpload, lateRead
    }
    public static let defaultTermsVersion = "2026-11-24"

    /// What `channels()` does for UI tests (`-AUNFixtureChannels`): the fixture channels, none, an error, or no answer.
    public enum Channels: String, Sendable { case all, none, failing, loading }

    let store = FixtureContentStore()
    let media = FixtureMediaStore()
    let termsState = FixtureTermsState()
    private let heldStore = FixtureHeldCommentStore()
    private let original = FixtureContentStore()
    let accountState: AccountState
    let termsMode: TermsMode
    /// Feature keys switched off for UI tests (`-AUNFixtureFeaturesOff upload,analytics`): `UserFeature` raw values, and
    /// `analytics`, whose routes then answer 404 `feature_off`.
    let featuresOff: Set<String>

    let channelsMode: Channels

    public init(
        accountState: AccountState = .creator, featuresOff: Set<String> = [], termsMode: TermsMode = .accepted,
        channels: Channels = .all
    ) {
        channelsMode = channels
        self.accountState = accountState
        self.featuresOff = featuresOff
        self.termsMode = termsMode
    }

    /// Uploads are refused until the Terms are accepted.
    private var refusesUploads: Bool { termsMode == .refuseUpload || termsMode == .lateRead }

    /// Every feature on for a creator; without a creator tier, uploads and channel creation are off.
    public func features(channelID: String?) async throws -> UserFeatures {
        var features = UserFeatures.all
        if accountState == .invitation {
            features = features.with(.upload, false).with(.createChannel, false)
        }
        for key in featuresOff { if let feature = UserFeature(rawValue: key) { features = features.with(feature, false) } }
        return features
    }

    /// Comments have one text, in the language they were written in: an Arabic app shows an Arabic channel's.
    public static var heldComments: [HeldComment] {
        let arabic = UserDefaults.standard.string(forKey: "AUNLanguage") == AppLanguage.ar.rawValue
        return [
            HeldComment(
                id: "fixture-held-1",
                text: arabic ? "جزاكم الله خيرًا، هل يوجد جزء ثالث؟" : "Jazakum Allah khayran, is there a part 3?",
                targetTitle: "Tafsir of Surah Al-Kahf, part 2",
                targetTitleLocalized: LocalizedText(
                    en: "Tafsir of Surah Al-Kahf, part 2", ar: "تفسير سورة الكهف، الجزء الثاني"),
                authorName: arabic ? "مريم حداد" : "Maryam Haddad", createdAt: Date(timeIntervalSince1970: 1_794_010_000),
                kind: .video, targetID: "fixture-content-2", authorUserID: "fixture-commenter-maryam"),
            HeldComment(
                id: "fixture-held-2",
                text: arabic
                    ? "ما المرجع المذكور في الدقيقة العاشرة؟" : "Which reference is mentioned at minute ten?",
                targetTitle: "Friday khutbah: patience",
                targetTitleLocalized: LocalizedText(en: "Friday khutbah: patience", ar: "خطبة الجمعة: الصبر"),
                authorName: arabic ? "عمر صالح" : "Omar Saleh", createdAt: Date(timeIntervalSince1970: 1_794_000_000),
                kind: .video, targetID: "fixture-content-3", authorUserID: "fixture-commenter-omar"),
        ]
    }

    /// Two held comments; `-AUNFixtureFeaturesOff comments` makes the route answer `feature_off`.
    public func heldComments(channelID: String, limit: Int) async throws -> HeldComments {
        try refuseIfOff("comments")
        let items = await heldStore.held(in: channelID)
        return HeldComments(items: Array(items.prefix(limit)), total: items.count)
    }

    public func moderateHeldComment(_ comment: HeldComment, action: HeldCommentModeration, channelID: String) async throws {
        try refuseIfOff("comments")
        await heldStore.moderate(comment, in: channelID)
    }

    public func reportHeldComment(id: String, reason: CommentReportReason, description: String?) async throws {
        try await heldStore.report(id, reason: reason)
    }

    public func hideCommentAuthor(userID: String, channelID: String) async throws {
        try refuseIfOff("comments")
        guard Self.heldComments.contains(where: { $0.authorUserID == userID }) else { throw CoreError.notFound }
        // Blocks apply to future comments, and fixtures don't receive new comments.
    }

    private func refuseIfOff(_ key: String) throws {
        if featuresOff.contains(key) { throw CoreError.featureOff }
    }

    public func creatorAccess() async throws -> CreatorAccess {
        if termsMode == .failed { throw CoreError.offline }
        if termsMode == .lateRead, await !termsState.canRead() { throw CoreError.offline }
        let accepted: Bool
        if refusesUploads {
            let refused = await termsState.refusedOnce
            let done = await termsState.acceptedAfterRefusal
            accepted = !refused || done
        } else {
            accepted = termsMode == .accepted
        }
        switch accountState {
        case .creator:
            return CreatorAccess(tierName: "Creator", termsAccepted: accepted, termsVersion: Self.defaultTermsVersion)
        case .invitation:
            return CreatorAccess(
                canUpload: false, canCreateChannel: false, termsAccepted: accepted,
                termsVersion: Self.defaultTermsVersion)
        case .pendingDeletion:
            return CreatorAccess(
                canUpload: false, canCreateChannel: false, pendingDeletion: true, termsAccepted: accepted,
                termsVersion: Self.defaultTermsVersion)
        }
    }

    public func acceptCreatorTerms(version: String) async throws {
        switch termsMode {
        case .acceptError: throw CoreError.http(status: 503)
        case .acceptVersionChanged:
            throw CoreError.refused(Refusal(code: Refusal.termsVersionChanged, currentVersion: "2026-12-01"))
        case .acceptSlow: try await Task.sleep(for: .seconds(5))
        case .refuseUpload, .lateRead: await termsState.markAccepted()
        case .accepted, .required, .failed: return
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

    public func channels() async throws -> [StudioChannel] {
        switch channelsMode {
        case .all: return Self.channels
        case .none: return []
        case .failing: throw CoreError.http(status: 500)
        case .loading:
            try await Task.sleep(for: .seconds(3600))
            return []
        }
    }

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
        if refusesUploads {
            let accepted = await termsState.acceptedAfterRefusal
            if !accepted {
                await termsState.markRefused()
                throw CoreError.refused(Refusal(code: Refusal.termsRequired))
            }
        }
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

    public func channelStats(channelID: String, period: DateInterval) async throws -> ChannelStats {
        try refuseIfOff("analytics")
        let daily = Self.fixtureDays(period)
        let videos = await store.videos.filter { $0.studioStatus == .published }
        return ChannelStats(
            totalViews: daily.reduce(0) { $0 + $1.views }, totalVideos: videos.count, totalSubscribers: 120, totalLikes: 90,
            totalComments: 25, engagementRate: 4.2,
            topVideos: videos.map {
                VideoStats(
                    videoID: $0.id, title: $0.title, views: $0.views / 4, watchTime: 7200, averageViewDuration: 310,
                    titleLocalized: $0.titleLocalized)
            }, daily: daily)
    }

    public func videoStats(videoID: String, period: DateInterval) async throws -> VideoStats {
        try refuseIfOff("analytics")
        let video = await store.videos.first { $0.id == videoID }
        return VideoStats(
            videoID: videoID, title: video?.title ?? "", views: (video?.views ?? 0) / 4, likes: 12, comments: 3, shares: 2,
            watchTime: 7200, averageViewDuration: 310, engagementRate: 5.1, rangeViews: (video?.views ?? 0) / 8,
            rangeLikes: 6, rangeComments: 2, daily: Self.fixtureDays(period), titleLocalized: video?.titleLocalized)
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

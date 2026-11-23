import Foundation

/// Caption drafts, the brand kit and assets that fixture actions change.
actor FixtureMediaStore {
    var drafts: [String: CaptionDraft] = [:]
    var jobs: [CaptionJob] = []
    var kit = BrandKit(name: BrandKit.Name(en: "Al Ummah Now", ar: "الأمة الآن"), logo: "a1b2c3d4e5f60001")
    var assets: [StudioAsset] = [
        StudioAsset(
            id: "a1b2c3d4e5f60001", kind: .image, name: "Channel logo", contentType: "image/png", bytes: 182_400,
            createdAt: Date(timeIntervalSince1970: 1_794_000_000)),
        StudioAsset(
            id: "a1b2c3d4e5f60002", kind: .video, name: "Intro", contentType: "video/mp4", bytes: 8_420_000,
            createdAt: Date(timeIntervalSince1970: 1_793_900_000)),
        StudioAsset(
            id: "a1b2c3d4e5f60003", kind: .audio, name: "Outro sound", contentType: "audio/mpeg", bytes: 640_000,
            createdAt: Date(timeIntervalSince1970: 1_793_800_000)),
    ]

    init() {
        let arabic = [
            ("بسم الله، نبدأ اليوم بتفسير سورة الكهف.", 0, 3_200),
            ("وهي سورة مكية، عدد آياتها مئة وعشر آيات.", 3_200, 7_000),
            ("نقرأ أولًا الآيات الأولى منها.", 7_000, 9_800),
        ]
        var cues = arabic.enumerated().map { index, item in
            CaptionCue(id: "c\(index + 1)", startMs: item.1, endMs: item.2, segments: [.speech(item.0)])
        }
        cues.append(
            CaptionCue(
                id: "c4", startMs: 9_800, endMs: 15_000,
                segments: [.quran(CaptionQuranSegment(range: "18:1:1-18:1:12", status: "confirmed"))]))
        drafts["ar"] = CaptionDraft(
            summary: CaptionDraftSummary(
                language: "ar", version: 3, origin: .onDevice, edited: true, cueCount: cues.count, pendingQuran: 1,
                updatedAt: Date(timeIntervalSince1970: 1_794_100_000)),
            cues: cues)
        let english = [
            ("In the name of Allah, today we begin the tafsir of Surah Al-Kahf.", 0, 3_200),
            ("It is a Makki surah of one hundred and ten ayat.", 3_200, 7_000),
        ]
        let enCues = english.enumerated().map { index, item in
            CaptionCue(id: "c\(index + 1)", startMs: item.1, endMs: item.2, segments: [.speech(item.0)])
        }
        drafts["en"] = CaptionDraft(
            summary: CaptionDraftSummary(
                language: "en", version: 2, origin: .translation, cueCount: enCues.count,
                updatedAt: Date(timeIntervalSince1970: 1_794_050_000), publishedVersion: 2,
                publishedAt: Date(timeIntervalSince1970: 1_794_060_000), track: .machine),
            cues: enCues)
    }

    func list() -> CaptionDraftList {
        CaptionDraftList(drafts: drafts.values.map(\.summary).sorted { $0.language < $1.language })
    }

    func draft(_ language: String) throws -> CaptionDraft {
        guard let draft = drafts[language] else { throw CoreError.notFound }
        return draft
    }

    func save(_ language: String, base: Int, cues: [CaptionCue]) throws -> CaptionDraftSummary {
        guard var draft = drafts[language] else { throw CoreError.notFound }
        guard draft.summary.version == base else { throw CoreError.conflict("draft_conflict") }
        draft.cues = CueEditing.forSaving(cues)
        draft.summary.version += 1
        draft.summary.edited = true
        draft.summary.cueCount = draft.cues.count
        draft.summary.updatedAt = Date()
        drafts[language] = draft
        return draft.summary
    }

    func publish(_ language: String, base: Int) throws -> CaptionDraftSummary {
        guard var draft = drafts[language] else { throw CoreError.notFound }
        guard draft.summary.version == base else { throw CoreError.conflict("draft_conflict") }
        draft.summary.publishedVersion = base
        draft.summary.publishedAt = Date()
        draft.summary.track = .machine
        drafts[language] = draft
        return draft.summary
    }

    func delete(_ language: String) { drafts[language] = nil }

    func start(_ language: String) -> CaptionJob {
        let job = CaptionJob(
            id: "fixture-job-\(jobs.count + 1)", language: language, status: .transcribing,
            progress: .init(done: 2, total: 9), minutesReserved: 12, createdAt: Date())
        jobs.insert(job, at: 0)
        return job
    }

    func cancel(_ id: String) throws -> CaptionJob {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { throw CoreError.notFound }
        jobs[index].status = .cancelled
        return jobs[index]
    }

    func setKit(_ kit: BrandKit) { self.kit = kit }

    func add(name: String, bytes: Data) -> StudioAsset {
        let asset = StudioAsset(
            // swiftlint:disable:next display_format
            id: String(format: "a1b2c3d4e5f6%04x", assets.count + 1), kind: .image, name: name, contentType: "image/png",
            bytes: Int64(bytes.count), createdAt: Date())
        assets.insert(asset, at: 0)
        return asset
    }

    func remove(_ id: String) {
        assets.removeAll { $0.id == id }
        for keyPath in [\BrandKit.logo, \BrandKit.intro, \BrandKit.outro] where kit[keyPath: keyPath] == id {
            kit[keyPath: keyPath] = nil
        }
    }
}

extension FixtureStudioService: CaptionsServicing, InstitutionServicing, InsightsServicing, RenditionsServicing {
    public func captionDrafts(videoID: String, channelID: String?) async throws -> CaptionDraftList { await media.list() }

    public func captionDraft(videoID: String, language: String, channelID: String?) async throws -> CaptionDraft {
        try await media.draft(language)
    }

    public func saveCaptionDraft(
        videoID: String, language: String, baseVersion: Int, cues: [CaptionCue], channelID: String?
    ) async throws -> CaptionDraftSummary {
        try refuseWrites()
        return try await media.save(language, base: baseVersion, cues: cues)
    }

    public func deleteCaptionDraft(videoID: String, language: String, channelID: String?) async throws {
        try refuseWrites()
        await media.delete(language)
    }

    public func publishCaptionDraft(
        videoID: String, language: String, baseVersion: Int, replaceUpload: Bool, channelID: String?
    ) async throws -> CaptionDraftSummary {
        try refuseWrites()
        return try await media.publish(language, base: baseVersion)
    }

    public func captionJobs(videoID: String, channelID: String?) async throws -> [CaptionJob] { await media.jobs }

    public func startCaptionJob(videoID: String, language: String, replace: Bool, channelID: String?) async throws
        -> CaptionJob
    {
        try refuseWrites()
        return await media.start(language)
    }

    public func cancelCaptionJob(videoID: String, jobID: String, channelID: String?) async throws -> CaptionJob {
        try await media.cancel(jobID)
    }

    public func captionMinutes(videoID: String, channelID: String?) async throws -> CaptionMinutes {
        CaptionMinutes(
            monthLimit: 300, monthUsed: 84, remaining: 216, resetsAt: Date(timeIntervalSince1970: 1_796_083_200),
            minutesNeeded: 12)
    }

    public func submitOnDeviceTranscript(
        videoID: String, language: String, transcript: OnDeviceTranscript, channelID: String?
    ) async throws -> Int {
        try refuseWrites()
        return transcript.segments.count
    }

    public func brandKit(channelID: String?) async throws -> BrandKitState {
        // A team member acting as someone else's channel reads the owner's kit.
        let owner = channelID.map { id in Self.channels.first { $0.id == id }?.role == .owner } ?? true
        return BrandKitState(kit: await media.kit, saved: true, canEdit: owner)
    }

    public func saveBrandKit(_ kit: BrandKit) async throws -> BrandKit {
        try refuseWrites()
        await media.setKit(kit)
        return kit
    }

    public func assets(channelID: String?) async throws -> StudioAssetLibrary {
        let owner = channelID.map { id in Self.channels.first { $0.id == id }?.role == .owner } ?? true
        return StudioAssetLibrary(assets: await media.assets, canEdit: owner)
    }

    public func addAsset(name: String, bytes: Data) async throws -> StudioAsset {
        try refuseWrites()
        return await media.add(name: name, bytes: bytes)
    }

    public func assetData(id: String, channelID: String?) async throws -> Data { Data() }

    public func deleteAsset(id: String) async throws {
        try refuseWrites()
        await media.remove(id)
    }

    public func analyticsSummary(channelID: String?) async throws -> AnalyticsSummary {
        let videos = FixtureLibrary.watchable
        let views = videos.reduce(0) { $0 + $1.views }
        let likes = videos.reduce(0) { $0 + $1.likes }
        let comments = videos.reduce(0) { $0 + $1.comments }
        return AnalyticsSummary(
            totalViews: views, totalLikes: likes, totalComments: comments, totalSubscribers: FixtureLibrary.subscribers,
            totalVideos: videos.count, averageViewsPerVideo: Double(views / max(1, videos.count)),
            engagementRate: (Double(likes + comments) / Double(max(1, views)) * 1000).rounded() / 10)
    }

    public func dailyMetrics(channelID: String?, period: DateInterval) async throws -> [DailyMetric] {
        FixtureLibrary.daily(FixtureLibrary.watchable, period)
    }

    public func retention(videoID: String, period: DateInterval) async throws -> RetentionCurve {
        RetentionCurve(
            starts: 240,
            points: stride(from: 0, through: 100, by: 5).map { bucket in
                RetentionCurve.Point(bucket: Double(bucket), share: max(0.18, 1 - Double(bucket) / 125))
            })
    }

    public func createRenditions(
        videoID: String, rungs: [String], files: [StagedFile], encoder: String, channelID: String?
    ) async throws -> RenditionStaging {
        RenditionStaging(stagingID: "fixture-staging", maxFileBytes: 32 << 20)
    }

    public func putRenditionFile(
        videoID: String, stagingID: String, file: StagedFile, bytes: Data, channelID: String?
    ) async throws {}
    public func completeRenditions(videoID: String, stagingID: String, channelID: String?) async throws {}
    public func cancelRenditions(videoID: String, stagingID: String, channelID: String?) async throws {}
}

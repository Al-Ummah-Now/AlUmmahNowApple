import Foundation

/// What Studio needs from the outside world. Apps build the live one; tests and previews use fixtures.
public struct StudioServices: Sendable {
    public var environment: AppEnvironment
    public var accounts: any AccountServicing
    public var studio: any StudioServicing
    public var transfer: any TUSTransferring
    public var search: any SearchSuggesting
    /// Caption drafts and transcription (E19 19.4).
    public var captions: any CaptionsServicing
    /// Brand kit and shared assets (E19 19.9).
    public var institution: any InstitutionServicing
    /// Analytics beyond the overview (E19 19.6).
    public var insights: any InsightsServicing
    /// Pre-encoded renditions (D11).
    public var renditions: any RenditionsServicing
    /// Core's media engines; nil until the Studio build links a Core release that has them.
    public var media: StudioMediaEngines?
    /// False for fixtures: their upload queue lives in a temporary file.
    public var persistsUploads = true

    public init(
        environment: AppEnvironment, accounts: any AccountServicing, studio: any StudioServicing,
        transfer: any TUSTransferring, search: any SearchSuggesting
    ) {
        self.environment = environment
        self.accounts = accounts
        self.studio = studio
        self.transfer = transfer
        self.search = search
        // The API services (native and fixtures) serve these routes too; a stub that does not answers "not found".
        let fallback = UnavailableStudioRoutes()
        captions = studio as? any CaptionsServicing ?? fallback
        institution = studio as? any InstitutionServicing ?? fallback
        insights = studio as? any InsightsServicing ?? fallback
        renditions = studio as? any RenditionsServicing ?? fallback
    }

    /// Hermetic services. `signedIn` starts with the fixture creator already signed in, in `accountState`.
    public static func fixtures(
        signedIn: Bool = false, accountState: FixtureStudioService.AccountState = .creator
    ) -> StudioServices {
        var services = StudioServices(
            environment: .qa,
            accounts: FixtureAccountService(signedIn: signedIn ? [FixtureAccountService.creator] : []),
            studio: FixtureStudioService(accountState: accountState), transfer: FixtureTUSTransfer(),
            search: FixtureSearchService())
        services.persistsUploads = false
        return services
    }
}

/// Answers every media route with `notFound`, for test stubs of `StudioServicing` that do not serve them.
struct UnavailableStudioRoutes: CaptionsServicing, InstitutionServicing, InsightsServicing, RenditionsServicing {
    func captionDrafts(videoID: String, channelID: String?) async throws -> CaptionDraftList { throw CoreError.notFound }
    func captionDraft(videoID: String, language: String, channelID: String?) async throws -> CaptionDraft {
        throw CoreError.notFound
    }
    func saveCaptionDraft(
        videoID: String, language: String, baseVersion: Int, cues: [CaptionCue], channelID: String?
    ) async throws -> CaptionDraftSummary { throw CoreError.notFound }
    func deleteCaptionDraft(videoID: String, language: String, channelID: String?) async throws { throw CoreError.notFound }
    func publishCaptionDraft(
        videoID: String, language: String, baseVersion: Int, replaceUpload: Bool, channelID: String?
    ) async throws -> CaptionDraftSummary { throw CoreError.notFound }
    func captionJobs(videoID: String, channelID: String?) async throws -> [CaptionJob] { throw CoreError.notFound }
    func startCaptionJob(videoID: String, language: String, replace: Bool, channelID: String?) async throws -> CaptionJob {
        throw CoreError.notFound
    }
    func cancelCaptionJob(videoID: String, jobID: String, channelID: String?) async throws -> CaptionJob {
        throw CoreError.notFound
    }
    func captionMinutes(videoID: String, channelID: String?) async throws -> CaptionMinutes { throw CoreError.notFound }
    func submitOnDeviceTranscript(
        videoID: String, language: String, transcript: OnDeviceTranscript, channelID: String?
    ) async throws -> Int { throw CoreError.notFound }
    func brandKit(channelID: String?) async throws -> BrandKitState { throw CoreError.notFound }
    func saveBrandKit(_ kit: BrandKit) async throws -> BrandKit { throw CoreError.notFound }
    func assets(channelID: String?) async throws -> StudioAssetLibrary { throw CoreError.notFound }
    func addAsset(name: String, bytes: Data) async throws -> StudioAsset { throw CoreError.notFound }
    func assetData(id: String, channelID: String?) async throws -> Data { throw CoreError.notFound }
    func deleteAsset(id: String) async throws { throw CoreError.notFound }
    func analyticsSummary(channelID: String?) async throws -> AnalyticsSummary { throw CoreError.notFound }
    func dailyMetrics(channelID: String?, period: DateInterval) async throws -> [DailyMetric] { throw CoreError.notFound }
    func retention(videoID: String, period: DateInterval) async throws -> RetentionCurve { throw CoreError.notFound }
    func createRenditions(
        videoID: String, rungs: [String], files: [StagedFile], encoder: String, channelID: String?
    ) async throws -> RenditionStaging { throw CoreError.notFound }
    func putRenditionFile(
        videoID: String, stagingID: String, file: StagedFile, bytes: Data, channelID: String?
    ) async throws { throw CoreError.notFound }
    func completeRenditions(videoID: String, stagingID: String, channelID: String?) async throws { throw CoreError.notFound }
    func cancelRenditions(videoID: String, stagingID: String, channelID: String?) async throws { throw CoreError.notFound }
}

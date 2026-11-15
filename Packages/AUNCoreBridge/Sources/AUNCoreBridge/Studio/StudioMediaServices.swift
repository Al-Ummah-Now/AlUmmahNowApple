import Foundation

/// Caption drafts, server transcription and on-device transcripts of one video (AUN-CAPTIONS, E19 19.4).
public protocol CaptionsServicing: Sendable {
    func captionDrafts(videoID: String, channelID: String?) async throws -> CaptionDraftList
    func captionDraft(videoID: String, language: String, channelID: String?) async throws -> CaptionDraft
    /// Saves over `baseVersion`; `CoreError.conflict("draft_conflict")` when it changed meanwhile.
    func saveCaptionDraft(
        videoID: String, language: String, baseVersion: Int, cues: [CaptionCue], channelID: String?
    ) async throws -> CaptionDraftSummary
    func deleteCaptionDraft(videoID: String, language: String, channelID: String?) async throws
    /// `CoreError.conflict("replaces_upload")` when an uploaded track exists and `replaceUpload` is false.
    func publishCaptionDraft(
        videoID: String, language: String, baseVersion: Int, replaceUpload: Bool, channelID: String?
    ) async throws -> CaptionDraftSummary
    func captionJobs(videoID: String, channelID: String?) async throws -> [CaptionJob]
    func startCaptionJob(videoID: String, language: String, replace: Bool, channelID: String?) async throws -> CaptionJob
    func cancelCaptionJob(videoID: String, jobID: String, channelID: String?) async throws -> CaptionJob
    func captionMinutes(videoID: String, channelID: String?) async throws -> CaptionMinutes
    /// Queues a draft from a transcript made on this computer. `draft_exists` / `claim_pending` come back as
    /// `CoreError.conflict`; send `replace` only after asking.
    func submitOnDeviceTranscript(
        videoID: String, language: String, transcript: OnDeviceTranscript, channelID: String?
    ) async throws -> Int
}

/// Institution mode (E19 19.9): the account's brand kit and shared assets. Writes are owner-only (403 otherwise).
public protocol InstitutionServicing: Sendable {
    func brandKit(channelID: String?) async throws -> BrandKitState
    func saveBrandKit(_ kit: BrandKit) async throws -> BrandKit
    func assets(channelID: String?) async throws -> StudioAssetLibrary
    /// The server reads the type from the bytes; `CoreError.conflict("library_full")` when the library is full.
    func addAsset(name: String, bytes: Data) async throws -> StudioAsset
    func assetData(id: String, channelID: String?) async throws -> Data
    func deleteAsset(id: String) async throws
}

/// Analytics beyond the overview (E19 19.6).
public protocol InsightsServicing: Sendable {
    func analyticsSummary(channelID: String?) async throws -> AnalyticsSummary
    func dailyMetrics(channelID: String?, period: DateInterval) async throws -> [DailyMetric]
    func retention(videoID: String, period: DateInterval) async throws -> RetentionCurve
}

/// Renditions encoded on this computer (D11). `too_late` comes back as `CoreError.conflict("too_late")`.
public protocol RenditionsServicing: Sendable {
    func createRenditions(
        videoID: String, rungs: [String], files: [StagedFile], encoder: String, channelID: String?
    ) async throws -> RenditionStaging
    func putRenditionFile(
        videoID: String, stagingID: String, file: StagedFile, bytes: Data, channelID: String?
    ) async throws
    /// `CoreError.conflict("files_missing", missing:)` lists files to send again.
    func completeRenditions(videoID: String, stagingID: String, channelID: String?) async throws
    func cancelRenditions(videoID: String, stagingID: String, channelID: String?) async throws
}

extension NativeStudioService: CaptionsServicing, InstitutionServicing, InsightsServicing, RenditionsServicing {
    struct Success<T: Decodable>: Decodable { let data: T }

    private func captions(_ videoID: String) -> String { "/api/videos/\(Self.segment(videoID))/captions" }

    /// One path segment. Server ids and language codes are `[A-Za-z0-9_.-]`; anything else (a `/`, `..`) is refused
    /// rather than sent, so an id can never reach another route.
    static func segment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let valid =
            !value.isEmpty && value != "." && value != ".."
            && value.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
        return valid ? value : "_invalid_"
    }

    public func captionDrafts(videoID: String, channelID: String?) async throws -> CaptionDraftList {
        try await client.send(.get, "\(captions(videoID))/drafts", channelID: channelID, as: Success<CaptionDraftList>.self)
            .data
    }

    public func captionDraft(videoID: String, language: String, channelID: String?) async throws -> CaptionDraft {
        try await client.send(
            .get, "\(captions(videoID))/drafts/\(Self.segment(language))", channelID: channelID,
            as: Success<CaptionDraft>.self
        ).data
    }

    private struct SaveBody: Encodable {
        let baseVersion: Int
        let cues: [CaptionCue]
    }

    public func saveCaptionDraft(
        videoID: String, language: String, baseVersion: Int, cues: [CaptionCue], channelID: String?
    ) async throws -> CaptionDraftSummary {
        try await client.send(
            .put, "\(captions(videoID))/drafts/\(Self.segment(language))", channelID: channelID,
            body: SaveBody(baseVersion: baseVersion, cues: CueEditing.forSaving(cues)),
            as: Success<CaptionDraftSummary>.self
        ).data
    }

    public func deleteCaptionDraft(videoID: String, language: String, channelID: String?) async throws {
        try await client.sendRaw(.delete, "\(captions(videoID))/drafts/\(Self.segment(language))", channelID: channelID)
    }

    private struct PublishBody: Encodable {
        let baseVersion: Int
        let replaceUpload: Bool
    }
    private struct Published: Decodable { let draft: CaptionDraftSummary }

    public func publishCaptionDraft(
        videoID: String, language: String, baseVersion: Int, replaceUpload: Bool, channelID: String?
    ) async throws -> CaptionDraftSummary {
        try await client.send(
            .post, "\(captions(videoID))/drafts/\(Self.segment(language))/publish", channelID: channelID,
            body: PublishBody(baseVersion: baseVersion, replaceUpload: replaceUpload), as: Success<Published>.self
        ).data.draft
    }

    private struct Jobs: Decodable { let jobs: [CaptionJob] }
    private struct OneJob: Decodable { let job: CaptionJob }
    private struct JobBody: Encodable {
        let language: String
        let replace: Bool
    }

    public func captionJobs(videoID: String, channelID: String?) async throws -> [CaptionJob] {
        try await client.send(.get, "\(captions(videoID))/jobs", channelID: channelID, as: Success<Jobs>.self).data.jobs
    }

    public func startCaptionJob(videoID: String, language: String, replace: Bool, channelID: String?) async throws
        -> CaptionJob
    {
        try await client.send(
            .post, "\(captions(videoID))/jobs", channelID: channelID, body: JobBody(language: language, replace: replace),
            as: Success<OneJob>.self
        ).data.job
    }

    public func cancelCaptionJob(videoID: String, jobID: String, channelID: String?) async throws -> CaptionJob {
        try await client.send(
            .post, "\(captions(videoID))/jobs/\(Self.segment(jobID))/cancel", channelID: channelID, as: Success<OneJob>.self
        ).data.job
    }

    public func captionMinutes(videoID: String, channelID: String?) async throws -> CaptionMinutes {
        try await client.send(.get, "\(captions(videoID))/minutes", channelID: channelID, as: Success<CaptionMinutes>.self)
            .data
    }

    private struct Queued: Decodable { let segments: Int }

    public func submitOnDeviceTranscript(
        videoID: String, language: String, transcript: OnDeviceTranscript, channelID: String?
    ) async throws -> Int {
        try await client.send(
            .post, "\(captions(videoID))/drafts/\(Self.segment(language))/transcript", channelID: channelID,
            body: transcript, as: Success<Queued>.self
        ).data.segments
    }

    // MARK: Institution

    private struct KitEnvelope: Decodable { let kit: BrandKit }

    public func brandKit(channelID: String?) async throws -> BrandKitState {
        try await client.send(.get, "/api/studio/brand-kit", channelID: channelID, as: Success<BrandKitState>.self).data
    }

    public func saveBrandKit(_ kit: BrandKit) async throws -> BrandKit {
        try await client.send(.put, "/api/studio/brand-kit", body: kit, as: Success<KitEnvelope>.self).data.kit
    }

    public func assets(channelID: String?) async throws -> StudioAssetLibrary {
        try await client.send(.get, "/api/studio/assets", channelID: channelID, as: Success<StudioAssetLibrary>.self).data
    }

    public func addAsset(name: String, bytes: Data) async throws -> StudioAsset {
        let data = try await client.sendBytes(
            .post, "/api/studio/assets", query: [URLQueryItem(name: "name", value: String(name.prefix(80)))], bytes: bytes)
        do {
            return try StudioHTTPClient.decoder.decode(Success<StudioAsset>.self, from: data).data
        } catch {
            throw CoreError.decoding
        }
    }

    public func assetData(id: String, channelID: String?) async throws -> Data {
        try await client.sendRaw(.get, "/api/studio/assets/\(Self.segment(id))", channelID: channelID)
    }

    public func deleteAsset(id: String) async throws {
        try await client.sendRaw(.delete, "/api/studio/assets/\(Self.segment(id))")
    }

    // MARK: Insights (raw objects, no envelope)

    private func rangeQuery(_ period: DateInterval) -> [URLQueryItem] {
        [
            URLQueryItem(name: "dateFrom", value: period.start.ISO8601Format()),
            URLQueryItem(name: "dateTo", value: period.end.ISO8601Format()),
        ]
    }

    public func analyticsSummary(channelID: String?) async throws -> AnalyticsSummary {
        let query = channelID.map { [URLQueryItem(name: "channelId", value: $0)] } ?? []
        return try await client.send(.get, "/api/analytics/summary", query: query, as: AnalyticsSummary.self)
    }

    public func dailyMetrics(channelID: String?, period: DateInterval) async throws -> [DailyMetric] {
        var query = rangeQuery(period)
        if let channelID { query.append(URLQueryItem(name: "channelId", value: channelID)) }
        return try await client.send(.get, "/api/analytics/metrics", query: query, as: [DailyMetric].self)
    }

    public func retention(videoID: String, period: DateInterval) async throws -> RetentionCurve {
        try await client.send(
            .get, "/api/analytics/videos/\(Self.segment(videoID))/retention", query: rangeQuery(period),
            as: RetentionCurve.self)
    }

    // MARK: Renditions

    private func renditions(_ videoID: String) -> String { "/api/videos/\(Self.segment(videoID))/renditions" }

    private struct RenditionsBody: Encodable {
        let rungs: [String]
        let files: [StagedFile]
        let encoder: String
    }

    public func createRenditions(
        videoID: String, rungs: [String], files: [StagedFile], encoder: String, channelID: String?
    ) async throws -> RenditionStaging {
        try await client.send(
            .post, renditions(videoID), channelID: channelID,
            body: RenditionsBody(rungs: rungs, files: files, encoder: encoder), as: Success<RenditionStaging>.self
        ).data
    }

    public func putRenditionFile(
        videoID: String, stagingID: String, file: StagedFile, bytes: Data, channelID: String?
    ) async throws {
        guard let parts = file.parts else { throw CoreError.invalid("file_not_declared") }
        guard Int64(bytes.count) == file.bytes else { throw CoreError.invalid("size_mismatch") }
        try await client.sendBytes(
            .put,
            "\(renditions(videoID))/\(Self.segment(stagingID))/files/\(Self.segment(parts.rung))/\(Self.segment(parts.file))",
            channelID: channelID, bytes: bytes)
    }

    public func completeRenditions(videoID: String, stagingID: String, channelID: String?) async throws {
        try await client.sendRaw(.post, "\(renditions(videoID))/\(Self.segment(stagingID))/complete", channelID: channelID)
    }

    public func cancelRenditions(videoID: String, stagingID: String, channelID: String?) async throws {
        try await client.sendRaw(.delete, "\(renditions(videoID))/\(Self.segment(stagingID))", channelID: channelID)
    }
}

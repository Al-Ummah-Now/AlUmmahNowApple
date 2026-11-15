import AUNCoreBridge
import Foundation
import Observation

/// A message by L10n key with its values, as `MessageBanner` shows it.
typealias StudioMessage = (key: String, values: [String])

/// One video's caption drafts, transcription jobs and caption minutes (E19 19.4).
@MainActor @Observable
final class CaptionsModel {
    enum Load: Equatable { case loading, loaded, failed }

    let videoID: String
    let channelID: String
    let services: StudioServices
    private(set) var load: Load = .loading
    private(set) var list = CaptionDraftList(drafts: [])
    private(set) var jobs: [CaptionJob] = []
    private(set) var minutes: CaptionMinutes?
    private(set) var busy = false
    var message: StudioMessage?
    /// Asks before an action replaces something (`draft_exists`, `replaces_upload`).
    var pendingReplace: PendingReplace?
    /// Polling waits 2 s, 4 s, 8 s… up to 30 s while a job runs or a draft is being written.
    private(set) var pollDelay: Duration = .seconds(2)
    /// Tests skip the waits.
    var pause: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    enum PendingReplace: Equatable, Identifiable {
        case transcribe(language: String)
        case publish(language: String, version: Int)
        var id: String {
            switch self {
            case .transcribe(let language): "t-\(language)"
            case .publish(let language, _): "p-\(language)"
            }
        }
    }

    init(videoID: String, channelID: String, services: StudioServices) {
        self.videoID = videoID
        self.channelID = channelID
        self.services = services
    }

    private var captions: any CaptionsServicing { services.captions }

    /// Something the server is still doing that will change the list.
    var isWorking: Bool { jobs.contains(where: \.isActive) || list.claims.contains { $0.status == .queued } }

    func refresh() async {
        do {
            async let drafts = captions.captionDrafts(videoID: videoID, channelID: channelID)
            async let jobs = captions.captionJobs(videoID: videoID, channelID: channelID)
            list = try await drafts
            self.jobs = (try? await jobs) ?? self.jobs
            load = .loaded
        } catch is CancellationError {
        } catch {
            AUNLog.studio.error("Caption drafts failed: \(error)")
            if load != .loaded { load = .failed }
        }
        minutes = try? await captions.captionMinutes(videoID: videoID, channelID: channelID)
    }

    /// Reloads with backoff while the server works, so a finished job or claim shows up on its own.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            guard isWorking else {
                pollDelay = .seconds(2)
                return
            }
            do { try await pause(pollDelay) } catch { return }
            pollDelay = min(pollDelay * 2, .seconds(30))
        }
    }

    private func run(_ action: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await action()
        } catch {
            AUNLog.studio.error("Caption action failed: \(error)")
            message = Self.message(for: error)
        }
    }

    func transcribe(language: String, replace: Bool = false) async {
        await run {
            do {
                let job = try await captions.startCaptionJob(
                    videoID: videoID, language: language, replace: replace, channelID: channelID)
                jobs.removeAll { $0.id == job.id }
                jobs.insert(job, at: 0)
                pollDelay = .seconds(2)
            } catch CoreError.conflict("draft_exists", _) {
                pendingReplace = .transcribe(language: language)
            }
        }
    }

    func cancel(_ job: CaptionJob) async {
        await run {
            let cancelled = try await captions.cancelCaptionJob(videoID: videoID, jobID: job.id, channelID: channelID)
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = cancelled }
            message = ("studio.captions.jobs.cancelled", [])
            await refresh()
        }
    }

    func publish(_ draft: CaptionDraftSummary, replaceUpload: Bool = false) async {
        await run {
            do {
                _ = try await captions.publishCaptionDraft(
                    videoID: videoID, language: draft.language, baseVersion: draft.version, replaceUpload: replaceUpload,
                    channelID: channelID)
                message = ("studio.captions.published", [])
                await refresh()
            } catch CoreError.conflict("replaces_upload", _) {
                pendingReplace = .publish(language: draft.language, version: draft.version)
            }
        }
    }

    func delete(_ draft: CaptionDraftSummary) async {
        await run {
            try await captions.deleteCaptionDraft(videoID: videoID, language: draft.language, channelID: channelID)
            list.drafts.removeAll { $0.language == draft.language }
            message = ("studio.captions.deleted", [])
        }
    }

    enum SubmitResult: Equatable { case sent, draftExists, failed }

    /// Sends a transcript made on this computer. `draftExists` means asking before sending again with `replace`.
    func submit(_ transcript: OnDeviceTranscript, language: String) async -> SubmitResult {
        var result = SubmitResult.failed
        await run {
            do {
                _ = try await captions.submitOnDeviceTranscript(
                    videoID: videoID, language: language, transcript: transcript, channelID: channelID)
                result = .sent
                message = ("studio.captions.onDevice.sent", [])
                pollDelay = .seconds(2)
                await refresh()
            } catch CoreError.conflict("draft_exists", _) {
                result = .draftExists
            }
        }
        return result
    }

    static func message(for error: any Error) -> StudioMessage {
        let key: String
        switch error as? CoreError {
        case .conflict("claim_pending", _): key = "studio.error.captions.pending"
        case .conflict("draft_conflict", _): key = "studio.error.captions.conflict"
        case .refused(let refusal) where refusal.code == Refusal.upgradeRequired: key = "studio.error.captions.minutes"
        case .http(status: 402): key = "studio.error.captions.minutes"
        case .invalid("invalid_transcript"): key = "studio.error.captions.transcript"
        default:
            let failure = StudioFailure.message(error)
            return (failure.key, failure.values)
        }
        return (key, [])
    }

}

/// The cue editor of one draft: undo/redo over the cues, save over the loaded version, publish what is saved.
@MainActor @Observable
final class CaptionEditorModel {
    enum Save: Equatable { case saved, unsaved, saving, failed, conflict }

    let videoID: String
    let channelID: String
    let language: String
    let services: StudioServices
    private(set) var summary: CaptionDraftSummary?
    private(set) var history = SnapshotHistory<[CaptionCue]>([])
    private(set) var save: Save = .saved
    private(set) var loadFailed = false
    var selection: CaptionCue.ID?
    var message: StudioMessage?
    /// Publishing would replace subtitles the creator uploaded: ask first.
    var confirmReplaceUpload = false

    init(videoID: String, channelID: String, language: String, services: StudioServices) {
        self.videoID = videoID
        self.channelID = channelID
        self.language = language
        self.services = services
    }

    var cues: [CaptionCue] { history.current }
    var selectedIndex: Int? { selection.flatMap { id in cues.firstIndex { $0.id == id } } }

    func load() async {
        do {
            let draft = try await services.captions.captionDraft(videoID: videoID, language: language, channelID: channelID)
            summary = draft.summary
            history.reset(draft.cues)
            save = .saved
            loadFailed = false
            if selection == nil { selection = draft.cues.first?.id }
        } catch is CancellationError {
        } catch {
            AUNLog.studio.error("Caption draft failed: \(error)")
            loadFailed = summary == nil
        }
    }

    /// Counts edits, so the view can save a moment after the last one.
    private(set) var editCount = 0
    private var typing: (cue: String, segment: Int, at: Date)?

    /// Applies an edit to a copy of the cues; recorded only when something changed.
    func edit(amending: Bool = false, _ change: (inout [CaptionCue]) -> Void) {
        var next = cues
        change(&next)
        guard next != cues else { return }
        if amending { history.amend(next) } else { history.record(next) }
        if !amending { typing = nil }
        save = .unsaved
        editCount += 1
    }

    /// Typing in one segment within a second and a half of the last keystroke is one undo step.
    func setText(_ text: String, cue index: Int, segment: Int, now: Date = Date()) {
        guard cues.indices.contains(index) else { return }
        let id = cues[index].id
        let continuing = typing.map { $0.cue == id && $0.segment == segment && now.timeIntervalSince($0.at) < 1.5 } ?? false
        edit(amending: continuing) { CueEditing.setText(text, cue: index, segment: segment, in: &$0) }
        typing = (id, segment, now)
    }

    func split(at offset: Int, segment: Int) {
        guard let index = selectedIndex else { return }
        edit { CueEditing.split(cue: index, segment: segment, at: offset, in: &$0) }
    }

    func mergeWithNext() {
        guard let index = selectedIndex else { return }
        edit { CueEditing.mergeWithNext(cue: index, in: &$0) }
    }

    func nudge(_ edge: CueEditing.Edge, by delta: Int) {
        guard let index = selectedIndex else { return }
        edit { CueEditing.nudge(edge, by: delta, cue: index, in: &$0) }
    }

    func deleteSelected() {
        guard let index = selectedIndex else { return }
        edit { CueEditing.delete(cue: index, in: &$0) }
        selection = cues.indices.contains(index) ? cues[index].id : cues.last?.id
    }

    func undo() {
        guard history.undo() != nil else { return }
        typing = nil
        save = .unsaved
        editCount += 1
    }

    func redo() {
        guard history.redo() != nil else { return }
        typing = nil
        save = .unsaved
        editCount += 1
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    @discardableResult
    func saveNow() async -> Bool {
        guard let summary, save != .saving else { return false }
        save = .saving
        do {
            self.summary = try await services.captions.saveCaptionDraft(
                videoID: videoID, language: language, baseVersion: summary.version, cues: cues, channelID: channelID)
            // The server drops blank text and empty cues: show what it kept.
            history.reset(CueEditing.forSaving(cues))
            save = .saved
            return true
        } catch CoreError.conflict("draft_conflict", _) {
            save = .conflict
        } catch {
            AUNLog.studio.error("Saving captions failed: \(error)")
            save = .failed
            message = CaptionsModel.message(for: error)
        }
        return false
    }

    /// Saves first when there are changes, then publishes the saved version.
    func publish(replaceUpload: Bool = false) async -> Bool {
        if save != .saved, !(await saveNow()) { return false }
        guard let summary else { return false }
        do {
            self.summary = try await services.captions.publishCaptionDraft(
                videoID: videoID, language: language, baseVersion: summary.version, replaceUpload: replaceUpload,
                channelID: channelID)
            message = ("studio.captions.published", [])
            return true
        } catch CoreError.conflict("replaces_upload", _) {
            confirmReplaceUpload = true
            return false
        } catch {
            message = CaptionsModel.message(for: error)
            return false
        }
    }
}

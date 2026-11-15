import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Captions: pick a video of the channel, then its drafts, transcription and the cue editor.
struct CaptionsView: View {
    @Environment(\.l10n) private var l10n
    let services: StudioServices
    let channelID: String
    @State private var videos: [StudioVideo] = []
    @State private var search = ""
    @State private var selected: StudioVideo.ID?
    @State private var failed = false
    @State private var loaded = false

    var body: some View {
        HStack(spacing: 0) {
            videoList.frame(width: 280)
            Divider()
            Group {
                if let video = videos.first(where: { $0.id == selected }) {
                    CaptionsPanel(services: services, channelID: channelID, video: video).id(video.id)
                } else {
                    EmptyStateView(title: l10n("studio.captions.pick"), message: l10n("studio.captions.pickMessage"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fanousPage()
        .navigationTitle(l10n("studio.captions.title"))
        .task(id: search) { await load() }
    }

    private var videoList: some View {
        VStack(spacing: 0) {
            TextField(l10n("studio.content.search"), text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(FanousScale.spacingMd)
                .accessibilityIdentifier("captions-search")
            if failed && videos.isEmpty {
                ErrorStateView { Task { await load() } }
            } else if !loaded {
                ThemeLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if videos.isEmpty {
                EmptyStateView(title: l10n("studio.captions.noVideos"), message: "")
            } else {
                List(videos, selection: $selected) { video in
                    VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                        Text(video.displayTitle(l10n.language)).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                            .lineLimit(2)
                        if let duration = video.durationSeconds {
                            Text(DisplayFormat.duration(duration, l10n.language)).fanousFont(.caption)
                                .foregroundStyle(Fanous.textSecondary)
                        }
                    }
                    .tag(video.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("captions-video-\(video.id)")
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func load() async {
        if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
        do {
            let page = try await services.studio.content(
                channelID: channelID, query: ContentQuery(status: .published, text: search, limit: 50), cursor: nil)
            videos = page.items
            if selected == nil { selected = videos.first?.id }
            failed = false
        } catch is CancellationError {
            return
        } catch {
            AUNLog.studio.error("Captions videos failed: \(error)")
            failed = true
        }
        loaded = true
    }
}

/// The name of a language code in the app language (`videoLanguage.*`, else the system's name).
func languageName(_ code: String, _ l10n: L10n) -> String {
    let key = "videoLanguage.\(code)"
    let known = l10n(key)
    if !known.hasPrefix("⟦") { return known }
    return l10n.language.locale.localizedString(forLanguageCode: code) ?? code
}

/// One video's caption drafts, jobs and minutes.
struct CaptionsPanel: View {
    @Environment(\.l10n) private var l10n
    @State private var model: CaptionsModel
    @State private var editing: String?
    @State private var deleting: CaptionDraftSummary?
    @State private var cancelling: CaptionJob?
    @State private var onDevice = false
    @State private var language: String
    let video: StudioVideo

    init(services: StudioServices, channelID: String, video: StudioVideo) {
        self.video = video
        _model = State(initialValue: CaptionsModel(videoID: video.id, channelID: channelID, services: services))
        _language = State(initialValue: video.language ?? "ar")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                Text(video.displayTitle(l10n.language)).fanousFont(.title).foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                switch model.load {
                case .loading: ThemeLoader().frame(maxWidth: .infinity, minHeight: 200)
                case .failed: ErrorStateView { Task { await model.refresh() } }
                case .loaded:
                    drafts
                    if !model.jobs.filter(\.isActive).isEmpty || !model.list.claims.isEmpty { activity }
                    create
                }
            }
            .padding(FanousScale.spacingLg)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.isWorking) { await model.poll() }
        .overlay(alignment: .bottom) { MessageBanner(message: $model.message) }
        .sheet(item: Binding(get: { editing.map(EditingLanguage.init) }, set: { editing = $0?.id })) { item in
            CaptionEditorView(
                model: CaptionEditorModel(
                    videoID: model.videoID, channelID: model.channelID, language: item.id, services: model.services)
            ) {
                Task { await model.refresh() }
            }
        }
        .sheet(isPresented: $onDevice) {
            OnDeviceTranscribeView(captions: model, language: language)
        }
        .sheet(item: $deleting) { draft in
            ConfirmSheet(
                title: l10n("studio.captions.deleteTitle"), message: l10n("studio.captions.deleteBody"),
                actionTitle: l10n("studio.captions.deleteDraft")
            ) { Task { await model.delete(draft) } }
        }
        .sheet(item: $cancelling) { job in
            ConfirmSheet(
                title: l10n("studio.captions.jobs.cancelTitle"), message: l10n("studio.captions.jobs.cancelBody"),
                actionTitle: l10n("studio.captions.jobs.cancelConfirm")
            ) { Task { await model.cancel(job) } }
        }
        .sheet(item: $model.pendingReplace) { pending in replaceSheet(pending) }
    }

    private struct EditingLanguage: Identifiable { let id: String }

    @ViewBuilder private func replaceSheet(_ pending: CaptionsModel.PendingReplace) -> some View {
        switch pending {
        case .transcribe(let language):
            ConfirmSheet(
                title: l10n("studio.captions.jobs.replaceTitle"),
                message: l10n("studio.captions.jobs.replaceBody", languageName(language, l10n)),
                actionTitle: l10n("studio.captions.replace")
            ) { Task { await model.transcribe(language: language, replace: true) } }
        case .publish(let language, let version):
            ConfirmSheet(
                title: l10n("studio.captions.replaceUploadTitle"),
                message: l10n("studio.captions.replaceUploadBody", languageName(language, l10n)),
                actionTitle: l10n("studio.captions.replace")
            ) {
                if let draft = model.list.drafts.first(where: { $0.language == language && $0.version == version }) {
                    Task { await model.publish(draft, replaceUpload: true) }
                }
            }
        }
    }

    // MARK: Drafts

    private var drafts: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            Text(l10n("studio.captions.draftsTitle")).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(l10n("studio.captions.draftsHint")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
            if model.list.drafts.isEmpty {
                Text(l10n("studio.captions.noDrafts")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                    .padding(.vertical, FanousScale.spacingSm)
            }
            ForEach(model.list.drafts) { draft in draftRow(draft) }
        }
    }

    private func draftRow(_ draft: CaptionDraftSummary) -> some View {
        HStack(alignment: .top, spacing: FanousScale.spacingMd) {
            VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                HStack(spacing: FanousScale.spacingSm) {
                    Text(languageName(draft.language, l10n)).fanousFont(.label).foregroundStyle(Fanous.textPrimary)
                    StatusChip(text: l10n(statusKey(draft)), emphasised: draft.isPublished && !draft.isOutdated)
                }
                if let origin = draft.origin {
                    Text(l10n("studio.captions.origin.\(origin.rawValue)")).fanousFont(.caption)
                        .foregroundStyle(Fanous.textSecondary)
                        .accessibilityIdentifier("draft-origin-\(draft.language)")
                }
                Text(l10n("studio.captions.cues", draft.cueCount.formatted(.number.locale(l10n.language.locale))))
                    .fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                if draft.pendingQuran > 0 {
                    Text(
                        l10n(
                            "studio.captions.quranPending", draft.pendingQuran.formatted(.number.locale(l10n.language.locale)))
                    )
                    .fanousFont(.caption).foregroundStyle(Fanous.accent)
                }
            }
            Spacer(minLength: FanousScale.spacingMd)
            Button(l10n("studio.captions.edit")) { editing = draft.language }
                .buttonStyle(FanousButtonStyle(.secondary))
                .accessibilityIdentifier("draft-edit-\(draft.language)")
            Button(l10n("studio.captions.publish")) { Task { await model.publish(draft) } }
                .buttonStyle(FanousButtonStyle(.primary))
                .disabled(model.busy || (draft.isPublished && !draft.isOutdated))
                .accessibilityIdentifier("draft-publish-\(draft.language)")
            Button {
                deleting = draft
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(FanousIconButtonStyle())
            .accessibilityLabel(l10n("studio.captions.deleteDraft"))
            .accessibilityIdentifier("draft-delete-\(draft.language)")
        }
        .padding(FanousScale.spacingMd)
        .fanousMaterial(.card) { .rounded($0.md) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("draft-\(draft.language)")
    }

    private func statusKey(_ draft: CaptionDraftSummary) -> String {
        if draft.isOutdated { return "studio.captions.status.outdated" }
        return draft.isPublished ? "studio.captions.status.published" : "studio.captions.status.draft"
    }

    // MARK: Activity

    private var activity: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            ForEach(model.jobs.filter(\.isActive)) { job in
                HStack {
                    ProgressView(value: job.progress.map { Double($0.done) / Double(max($0.total, 1)) })
                        .frame(width: 120)
                        .accessibilityHidden(true)
                    Text(l10n("studio.captions.jobs.chip", languageName(job.language, l10n), stepText(job)))
                        .fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                    Spacer()
                    if job.status != .postprocessing {
                        Button(l10n("studio.captions.jobs.cancel")) { cancelling = job }
                            .buttonStyle(FanousButtonStyle(.ghost))
                            .accessibilityIdentifier("job-cancel-\(job.id)")
                    }
                }
                .accessibilityElement(children: .combine)
                if job.status == .waitingBudget {
                    Text(l10n("studio.captions.jobs.waitingBudgetHint")).fanousFont(.caption)
                        .foregroundStyle(Fanous.textSecondary)
                }
            }
            ForEach(model.list.claims, id: \.language) { claim in
                Text(
                    claim.status == .queued
                        ? l10n("studio.captions.preparing", languageName(claim.language, l10n))
                        : l10n("studio.captions.claimFailed")
                )
                .fanousFont(.body).foregroundStyle(claim.status == .failed ? Fanous.errorText : Fanous.textSecondary)
            }
        }
        .padding(FanousScale.spacingMd)
        .fanousMaterial(.card) { .rounded($0.md) }
        .accessibilityIdentifier("captions-activity")
    }

    private func stepText(_ job: CaptionJob) -> String {
        let format = { (value: Int) in value.formatted(.number.locale(l10n.language.locale)) }
        switch job.status {
        case .transcribing:
            if let progress = job.progress, progress.total > 0 {
                return l10n("studio.captions.jobs.step.transcribing", format(progress.done), format(progress.total))
            }
            return l10n("studio.captions.jobs.step.transcribingStart")
        case .waitingBudget: return l10n("studio.captions.jobs.step.waiting_budget")
        case .extracting: return l10n("studio.captions.jobs.step.extracting")
        case .postprocessing: return l10n("studio.captions.jobs.step.postprocessing")
        default: return l10n("studio.captions.jobs.step.queued")
        }
    }

    // MARK: Create

    private var create: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
            Text(l10n("studio.captions.jobs.title")).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(l10n("studio.captions.jobs.body")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(l10n("studio.captions.jobs.languageLabel"), selection: $language) {
                ForEach(VideoLanguage.allCases, id: \.rawValue) { Text(languageName($0.rawValue, l10n)).tag($0.rawValue) }
            }
            .frame(maxWidth: 360)
            .accessibilityIdentifier("captions-language")
            if let minutes = model.minutes { MinutesMeter(minutes: minutes) }
            HStack(spacing: FanousScale.spacingMd) {
                VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                    Button(l10n("studio.captions.jobs.server")) { Task { await model.transcribe(language: language) } }
                        .buttonStyle(FanousButtonStyle(.primary))
                        .disabled(model.busy || !(model.minutes?.canStart ?? true) || model.minutes?.minutesNeeded == nil)
                        .accessibilityIdentifier("captions-transcribe-server")
                    if let note = costNote { Text(note).fanousFont(.caption).foregroundStyle(Fanous.textSecondary) }
                }
                if model.services.transcription?.isAvailable == true {
                    VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                        Button(l10n("studio.captions.onDevice.action")) { onDevice = true }
                            .buttonStyle(FanousButtonStyle(.secondary))
                            .accessibilityIdentifier("captions-transcribe-device")
                        Text(l10n("studio.captions.onDevice.hint")).fanousFont(.caption)
                            .foregroundStyle(Fanous.textSecondary)
                    }
                }
            }
        }
        .padding(FanousScale.spacingLg)
        .fanousMaterial(.card) { .rounded($0.lg) }
    }

    private var costNote: String? {
        guard let minutes = model.minutes else { return nil }
        guard let needed = minutes.minutesNeeded else { return l10n("studio.captions.jobs.notReady") }
        let format = { (value: Double) in value.formatted(.number.precision(.fractionLength(0)).locale(l10n.language.locale)) }
        if minutes.hasNoPlan { return l10n("studio.captions.jobs.noPlan") }
        if minutes.unlimited { return l10n("studio.captions.jobs.costUnlimited", format(needed)) }
        let remaining = minutes.remaining ?? 0
        if remaining <= 0 { return nil }
        if needed > remaining {
            return l10n("studio.captions.jobs.costOver", format(needed), format(remaining), format(needed - remaining))
        }
        return l10n("studio.captions.jobs.cost", format(needed), format(remaining))
    }
}

/// Draft, Published or Edited since publishing.
struct StatusChip: View {
    let text: String
    let emphasised: Bool

    var body: some View {
        Text(text)
            .fanousFont(.caption)
            .foregroundStyle(emphasised ? Fanous.successText : Fanous.textSecondary)
            .padding(.horizontal, FanousScale.spacingSm)
            .padding(.vertical, 2)
            .overlay(Capsule().stroke(emphasised ? Fanous.successText : Fanous.outline, lineWidth: 1))
    }
}

/// Caption minutes used this month, as the web meter words it.
struct MinutesMeter: View {
    @Environment(\.l10n) private var l10n
    let minutes: CaptionMinutes

    var body: some View {
        let format = { (value: Double) in value.formatted(.number.precision(.fractionLength(0)).locale(l10n.language.locale)) }
        let date = minutes.resetsAt?.formatted(.dateTime.day().month(.wide).locale(l10n.language.locale)) ?? ""
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            if minutes.unlimited {
                Text(l10n("studio.captions.jobs.meterUnlimited"))
            } else if let limit = minutes.monthLimit, !minutes.hasNoPlan {
                ProgressView(value: min(minutes.monthUsed, limit), total: max(limit, 1))
                    .accessibilityLabel(l10n("studio.captions.jobs.meterLabel"))
                if minutes.overdraft > 0 {
                    Text(
                        l10n(
                            "studio.captions.jobs.meterOver", format(minutes.monthUsed), format(limit),
                            format(minutes.overdraft)))
                } else {
                    Text(l10n("studio.captions.jobs.meter", format(minutes.monthUsed), format(limit), date))
                }
                if minutes.held > 0 { Text(l10n("studio.captions.jobs.meterHeld", format(minutes.held))) }
                if minutes.packsRemaining > 0 { Text(l10n("studio.captions.jobs.meterPacks", format(minutes.packsRemaining))) }
                if let remaining = minutes.remaining, remaining <= 0 {
                    Text(
                        minutes.overdraft > 0
                            ? l10n("studio.captions.jobs.outOver", format(minutes.overdraft), date)
                            : l10n("studio.captions.jobs.outUsed", date)
                    )
                    .foregroundStyle(Fanous.errorText)
                } else if minutes.warning {
                    Text(l10n("studio.captions.jobs.meterWarning"))
                }
            } else {
                Text(l10n("studio.captions.jobs.noPlan"))
            }
        }
        .fanousFont(.caption)
        .foregroundStyle(Fanous.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("captions-minutes")
    }
}

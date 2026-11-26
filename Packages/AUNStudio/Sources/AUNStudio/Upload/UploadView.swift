import AUNCoreBridge
import AUNDesign
import SwiftUI

#if os(iOS)
    import PhotosUI
#endif

/// A text field that keeps its label visible above it, so fields stay told apart after typing.
struct LabeledField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    var identifier = ""

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            Text(label).fanousFont(.caption).foregroundStyle(Fanous.textSecondary).accessibilityHidden(true)
            TextField(label, text: $text, prompt: fanousPrompt(prompt)).autocorrectionDisabled().fanousFieldAlignment()
                .accessibilityIdentifier(identifier)
        }
    }
}

extension View {
    /// Form rows on the raised card surface, as the cards elsewhere in Studio.
    func studioRows() -> some View { listRowBackground(Rectangle().fill(Fanous.surfaceRaised)) }
}

/// Upload one video or many: pick files, set values for all of them, follow the queue.
struct UploadView: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession
    private var composer: UploadComposer { session.composer }
    @State private var importing = false
    #if os(iOS)
        @State private var photoPicks: [PhotosPickerItem] = []
        @State private var loadingPhotos = false
    #endif

    /// Why this account cannot upload at all: its videos data is pending deletion, or it is banned. Without a creator
    /// tier there is no Upload tab (`StudioSession.shows(.upload)`), so this screen never explains tiers.
    private var uploadRefusal: Refusal? { session.accountState }

    var body: some View {
        // Two columns when there is room (iPad landscape, Mac): the files, send and queue beside Set for all. One
        // column otherwise, in the same order as before.
        GeometryReader { proxy in
            let gate = session.creatorTerms.gate
            let twoColumns = gate == nil && proxy.size.width >= 900 && setForAllShown
            HStack(alignment: .top, spacing: 0) {
                // The gate opens in the same form, from its top: another scroll view would lose the header's light
                // status bar.
                ScrollViewReader { scroll in
                    Form {
                        if let gate {
                            termsGate(gate)
                        } else {
                            mainSections(includingSetForAll: !twoColumns)
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    #if os(iOS)
                        .contentMargins(.bottom, footerScrollMargin, for: .scrollContent)
                    #endif
                    .onChange(of: session.needsCreatorTerms) { _, needed in
                        if needed { scroll.scrollTo(Self.gateRow, anchor: .top) }
                    }
                }
                if twoColumns {
                    Form { setForAll }.formStyle(.grouped).scrollContentBackground(.hidden)
                        .frame(width: min(520, proxy.size.width * 0.45))
                }
            }
        }
        .fanousPage()
        .navigationTitle(l10n("studio.upload.title"))
        .task {
            let count = SampleVideos.requestedCount()
            guard count > 0, composer.files.isEmpty else { return }
            let samples = await SampleVideos.make(count: count, language: l10n.language)
            composer.add(samples.compactMap { PickedVideo.make(file: $0, ownsFile: true) })
        }
        .task(id: session.channel?.id) {
            if let channel = session.channel {
                await composer.loadPlaylists(channelID: channel.id, studio: session.services.studio)
            }
        }
        .fileImporter(
            isPresented: $importing, allowedContentTypes: StudioVideoFileTypes.allowed, allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { composer.add(urls.compactMap(Self.importFile)) }
        }
        #if os(macOS)
            .dropDestination(for: URL.self) { urls, _ in
                let picked = urls.compactMap(Self.importFile)
                composer.add(picked)
                return !picked.isEmpty
            }
        #endif
        #if os(iOS)
            .onChange(of: photoPicks) { _, items in Task { await loadPhotos(items) } }
        #endif
    }

    #if os(iOS)
        /// Extra scroll room for the channel note to clear the floating iPhone tab bar and its scroll-edge fade.
        private var footerScrollMargin: CGFloat? {
            if #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone, setForAllShown {
                return 80
            }
            return nil
        }
    #endif

    private static let gateRow = "creator-terms-row"

    /// The Terms wait for an agreement: the gate, and the uploads that wait with it.
    @ViewBuilder private func termsGate(_ gate: CreatorTerms.Gate) -> some View {
        Section {
            CreatorTermsGateView(session: session, gate: gate)
                .id(Self.gateRow)
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 36, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        UploadQueueSection(session: session).studioRows()
    }

    /// Set for all is shown once there are files to send to a channel.
    private var setForAllShown: Bool { uploadRefusal == nil && session.channel != nil && !composer.files.isEmpty }

    @ViewBuilder private var setForAll: some View {
        if setForAllShown, let channel = session.channel {
            SetForAllSection(composer: composer, channel: channel) {
                Task { await composer.loadPlaylists(channelID: channel.id, studio: session.services.studio) }
            }
        }
    }

    @ViewBuilder private func mainSections(includingSetForAll: Bool) -> some View {
        if let refusal = uploadRefusal {
            // The server would refuse every upload; say why instead of offering the picker.
            let key = StudioFailure.refusalMessage(refusal) ?? "studio.error.generic"
            Text(l10n(key)).foregroundStyle(Fanous.textSecondary).studioRows()
                .accessibilityIdentifier("upload-refused")
        } else if let channel = session.channel {
            filesSection.studioRows()
            if !composer.files.isEmpty {
                if includingSetForAll { setForAll }
                sendSection(channel).studioRows()
            }
        } else {
            Text(l10n("studio.channel.none")).foregroundStyle(Fanous.textSecondary).studioRows()
        }
        UploadQueueSection(session: session).studioRows()
    }

    // MARK: Files

    private var filesSection: some View {
        Section {
            ForEach(composer.files) { file in
                FileRow(composer: composer, id: file.id, channelName: session.channel?.displayName(l10n.language) ?? "")
            }
            // The pick actions at the trailing end (owner rule); Photos is the gold one on iPhone and iPad.
            HStack(spacing: FanousScale.spacingSm) {
                Spacer(minLength: 0)
                #if os(iOS)
                    if loadingPhotos { ProgressView().accessibilityLabel(l10n("common.loading")) }
                #endif
                Button {
                    importing = true
                } label: {
                    Label(l10n("studio.upload.fromFiles"), systemImage: "folder")
                }
                #if os(iOS)
                    .buttonStyle(FanousButtonStyle(.secondary))
                #else
                    .buttonStyle(FanousButtonStyle(.primary))
                #endif
                .accessibilityIdentifier("upload-files")
                #if os(iOS)
                    PhotosPicker(selection: $photoPicks, matching: .videos, preferredItemEncoding: .current) {
                        Label(l10n("studio.upload.fromPhotos"), systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(FanousButtonStyle(.primary))
                    .accessibilityIdentifier("upload-photos")
                #endif
            }
        } header: {
            Text(l10n("studio.upload.files")).fanousSectionText()
        } footer: {
            if composer.files.isEmpty {
                #if os(macOS)
                    Text(l10n("studio.upload.empty")).fanousSectionText()
                #else
                    Text(l10n("studio.upload.emptyMobile")).fanousSectionText()
                #endif
            }
        }
    }

    private func sendSection(_ channel: StudioChannel) -> some View {
        Section {
            let problem = composer.problem()
            Button {
                guard let account = session.account else { return }
                session.uploads.enqueue(composer.makeJobs(channel: channel, accountID: account.id, language: l10n.language))
            } label: {
                Text(l10n("studio.upload.send", DisplayFormat.number(composer.files.count, l10n.language)))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FanousButtonStyle(.primary))
            .disabled(problem != nil)
            .accessibilityIdentifier("upload-send")
            if let problem, !composer.files.isEmpty {
                Text(l10n(problem, DisplayFormat.number(Int(UploadComposer.minimumLead / 60), l10n.language))).fanousFont(
                    .caption
                ).foregroundStyle(Fanous.errorText)
                    .accessibilityIdentifier("upload-problem")
            }
        } footer: {
            Text(l10n("studio.upload.channelNote", channel.displayName(l10n.language)))
                .fanousSectionText()
                .accessibilityIdentifier("upload-channel-note")
        }
    }

    /// Keeps a picked file: a copy in the app's container on iOS, a security-scoped bookmark on the Mac.
    static func importFile(_ url: URL) -> PickedVideo? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
            let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil)
            return PickedVideo.make(file: url, ownsFile: false, bookmark: bookmark)
        #else
            guard let copy = try? copyIntoContainer(url) else { return nil }
            return PickedVideo.make(file: copy, ownsFile: true)
        #endif
    }

    static func copyIntoContainer(_ url: URL) throws -> URL {
        let directory = UploadStore.filesDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    #if os(iOS)
        private func loadPhotos(_ items: [PhotosPickerItem]) async {
            guard !items.isEmpty else { return }
            loadingPhotos = true
            defer {
                loadingPhotos = false
                photoPicks = []
            }
            let account = session.account?.id
            for item in items {
                guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { continue }
                let moved = try? Self.copyIntoContainer(movie.url)
                try? FileManager.default.removeItem(at: movie.url)
                // Copying took a while: the account it was picked under may be gone.
                if let moved, let picked = PickedVideo.make(file: moved, ownsFile: true), session.account?.id == account {
                    composer.add([picked])
                } else if let moved {
                    try? FileManager.default.removeItem(at: moved)
                }
            }
        }
    #endif
}

/// One picked file: its title as the pattern makes it, editable for this file only.
private struct FileRow: View {
    @Environment(\.l10n) private var l10n
    @Bindable var composer: UploadComposer
    let id: UUID
    let channelName: String

    var body: some View {
        // Looked up by id: the list can empty itself (after "Start upload") while this row is still drawn.
        if let index = composer.files.firstIndex(where: { $0.id == id }) {
            row(index, composer.files[index])
        }
    }

    private func row(_ index: Int, _ file: PickedVideo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FanousScale.spacingMd) {
            Image(systemName: "film").foregroundStyle(Fanous.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                TextField(
                    l10n("studio.upload.titleFor", file.fileName),
                    text: Binding(
                        get: { composer.files.first { $0.id == id }?.titleOverride ?? "" },
                        set: { value in
                            guard let current = composer.files.firstIndex(where: { $0.id == id }) else { return }
                            composer.files[current].titleOverride = value.isEmpty ? nil : value
                        }),
                    prompt: fanousPrompt(composer.title(at: index, channelName: channelName, language: l10n.language))
                )
                .fanousFieldAlignment()
                .accessibilityIdentifier("upload-title-\(index)")
                Text(
                    verbatim: DisplayFormat.meta(
                        [file.fileName, DisplayFormat.bytes(file.fileSize, l10n.language)], l10n.language)
                )
                .fanousFont(.caption).foregroundStyle(Fanous.textMuted)
            }
            Button {
                composer.remove(file.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Fanous.textSecondary)
            .accessibilityLabel(l10n("studio.upload.removeFile", file.fileName))
        }
    }
}

/// The values every picked file gets.
private struct SetForAllSection: View {
    @Environment(\.l10n) private var l10n
    @Bindable var composer: UploadComposer
    let channel: StudioChannel
    let retryPlaylists: () -> Void

    var body: some View {
        Section {
            HStack {
                TextField(
                    l10n("studio.upload.titlePattern"), text: $composer.settings.titlePattern,
                    prompt: fanousPrompt(l10n("studio.upload.titlePattern"))
                )
                .fanousFieldAlignment()
                .autocorrectionDisabled()
                .accessibilityIdentifier("upload-pattern")
                Menu {
                    ForEach(TitlePattern.tokens, id: \.self) { token in
                        Button(l10n("studio.token.\(token)")) { composer.settings.titlePattern += "{{\(token)}}" }
                    }
                } label: {
                    Label(l10n("studio.upload.insertToken"), systemImage: "curlybraces")
                }
                .accessibilityIdentifier("upload-token")
            }
            if composer.settings.titlePattern.contains("{{episode}}") {
                Stepper(
                    l10n(
                        "studio.upload.firstEpisode",
                        DisplayFormat.number(composer.settings.firstEpisode, l10n.language)),
                    value: $composer.settings.firstEpisode, in: 0...9999)
            }
            TextField(
                l10n("studio.upload.description"), text: $composer.settings.description,
                prompt: fanousPrompt(l10n("studio.upload.description")), axis: .vertical
            )
            .fanousFieldAlignment()
            .lineLimit(3...8)
            .accessibilityIdentifier("upload-description")
            Picker(l10n("studio.upload.category"), selection: $composer.settings.category) {
                Text(l10n("studio.upload.none")).tag(VideoCategory?.none)
                ForEach(VideoCategory.allCases, id: \.self) { Text(l10n("category.\($0.rawValue)")).tag(VideoCategory?.some($0)) }
            }
            .accessibilityIdentifier("upload-category")
            Picker(l10n("studio.upload.language"), selection: $composer.settings.language) {
                Text(l10n("studio.upload.none")).tag(VideoLanguage?.none)
                ForEach(VideoLanguage.allCases, id: \.self) {
                    Text(l10n("videoLanguage.\($0.rawValue)")).tag(VideoLanguage?.some($0))
                }
            }
            .accessibilityIdentifier("upload-language")
            Picker(l10n("studio.upload.visibility"), selection: $composer.settings.visibility) {
                ForEach(UploadVisibility.allCases, id: \.self) { Text(l10n("visibility.\($0.rawValue)")).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("upload-visibility")
            LabeledField(
                label: l10n("studio.upload.tags"), text: $composer.tagsText, prompt: l10n("studio.upload.tagsHint"),
                identifier: "upload-tags")
        } header: {
            Text(l10n(composer.files.count > 1 ? "studio.upload.setForAll" : "studio.upload.details")).fanousSectionText()
        } footer: {
            Text(l10n("studio.upload.tokensHelp")).fanousSectionText()
        }
        .studioRows()
        playlistsSection.studioRows()
        scheduleSection.studioRows()
    }

    @ViewBuilder private var playlistsSection: some View {
        Section {
            // The channel's playlists show as soon as the form opens: loading, then the list, empty or retry.
            if composer.playlistsLoading && composer.playlists.isEmpty {
                ProgressView().frame(maxWidth: .infinity).accessibilityLabel(l10n("common.loading"))
            } else if composer.playlistsFailed {
                HStack {
                    Text(l10n("common.error.load")).foregroundStyle(Fanous.errorText)
                    Spacer()
                    Button(l10n("common.retry"), action: retryPlaylists)
                        .accessibilityIdentifier("upload-playlists-retry")
                }
            } else if composer.playlists.isEmpty {
                Text(l10n("studio.upload.noPlaylists")).foregroundStyle(Fanous.textSecondary)
            }
            ForEach(composer.playlists) { playlist in
                Toggle(
                    isOn: Binding(
                        get: { composer.settings.playlistIDs.contains(playlist.id) },
                        set: { _ in composer.togglePlaylist(playlist.id) })
                ) {
                    Label(playlist.displayTitle(l10n.language), systemImage: playlist.isPublic ? "list.bullet" : "lock")
                }
                .accessibilityIdentifier("upload-playlist-\(playlist.id)")
            }
        } header: {
            Text(l10n("studio.upload.playlists")).fanousSectionText()
        }
    }

    @ViewBuilder private var scheduleSection: some View {
        Section {
            Toggle(l10n("studio.upload.schedule"), isOn: $composer.scheduleEnabled)
                .accessibilityIdentifier("upload-schedule")
            if composer.scheduleEnabled {
                DatePicker(
                    l10n("studio.upload.publishAt"),
                    selection: Binding(
                        get: { composer.settings.scheduleAt ?? UploadComposer.earliestSchedule() },
                        set: { composer.settings.scheduleAt = $0 }),
                    in: Date().addingTimeInterval(UploadComposer.minimumLead)...)
                if composer.files.count > 1 {
                    Stepper(
                        l10n(
                            "studio.upload.interval",
                            DisplayFormat.number(composer.settings.scheduleIntervalMinutes / 60, l10n.language)),
                        value: $composer.settings.scheduleIntervalMinutes, in: 0...(7 * 24 * 60), step: 60)
                }
            }
        } footer: {
            if composer.scheduleEnabled { Text(l10n("studio.upload.scheduleHelp")).fanousSectionText() }
        }
    }
}

/// The active account's uploads with progress and actions.
struct UploadQueueSection: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession

    var body: some View {
        let jobs = session.uploads.jobs.filter { $0.accountID == session.account?.id }
        if !jobs.isEmpty {
            Section {
                ForEach(jobs) { job in
                    UploadJobRow(job: job, queue: session.uploads, isTermsGateOpen: session.needsCreatorTerms)
                }
            } header: {
                HStack {
                    Text(l10n("studio.upload.queue")).fanousSectionText()
                    Spacer()
                    if jobs.contains(where: { $0.state == .done }) {
                        Button(l10n("studio.upload.clearDone")) { session.uploads.clearFinished() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("upload-clear-done")
                    }
                }
            } footer: {
                #if os(iOS)
                    Text(l10n("studio.upload.backgroundNote")).fanousSectionText()
                #endif
            }
        }
    }
}

struct UploadJobRow: View {
    @Environment(\.l10n) private var l10n
    let job: UploadJob
    let queue: UploadQueue
    let isTermsGateOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.title).fanousFont(.body).foregroundStyle(Fanous.textPrimary).lineLimit(2)
                Spacer(minLength: FanousScale.spacingSm)
                actions
            }
            ProgressView(value: job.fraction)
                .accessibilityLabel(l10n("studio.upload.progress", job.title))
                .accessibilityValue(DisplayFormat.percent(job.fraction, l10n.language))
            Text(status).fanousFont(.caption)
                .foregroundStyle(job.state == .failed ? Fanous.errorText : Fanous.textSecondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("upload-job-\(job.index)")
    }

    static func isPausedForTerms(_ job: UploadJob) -> Bool {
        job.state == .paused && job.failure == UploadQueue.termsRequiredKey
    }

    static func pausedStatusKey(for job: UploadJob) -> String {
        isPausedForTerms(job) ? "studio.upload.state.waitingForTerms" : "studio.upload.state.paused"
    }

    static func showsResumeAction(for job: UploadJob, isTermsGateOpen: Bool) -> Bool {
        guard job.state == .paused || job.state == .failed else { return false }
        return !(isPausedForTerms(job) && isTermsGateOpen)
    }

    private var status: String {
        switch job.state {
        case .waiting: l10n("studio.upload.state.waiting")
        case .preparing: l10n("studio.upload.state.preparing")
        case .uploading:
            l10n(
                "studio.upload.state.uploading",
                DisplayFormat.percent(job.fraction, l10n.language))
        case .finishing: l10n("studio.upload.state.finishing")
        case .paused: l10n(Self.pausedStatusKey(for: job))
        case .failed: l10n(job.failure ?? "studio.upload.error.generic")
        case .done:
            job.scheduleDate.map {
                l10n("studio.upload.state.scheduled", DisplayFormat.dateTime($0, l10n.language))
            } ?? l10n("studio.upload.state.done")
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: FanousScale.spacingSm) {
            switch job.state {
            case .preparing, .uploading, .waiting:
                Button(l10n("studio.upload.pause")) { queue.pause(job.id) }
                    .accessibilityIdentifier("upload-pause-\(job.index)")
            case .paused, .failed:
                if Self.showsResumeAction(for: job, isTermsGateOpen: isTermsGateOpen) {
                    Button(l10n(job.state == .failed ? "common.retry" : "studio.upload.resume")) { queue.resume(job.id) }
                        .accessibilityIdentifier("upload-resume-\(job.index)")
                }
                Button(l10n("studio.upload.remove")) { queue.remove(job.id) }
                    .accessibilityIdentifier("upload-remove-\(job.index)")
            case .finishing, .done:
                EmptyView()
            }
        }
        .buttonStyle(.borderless)
        .fanousFont(.caption)
    }
}

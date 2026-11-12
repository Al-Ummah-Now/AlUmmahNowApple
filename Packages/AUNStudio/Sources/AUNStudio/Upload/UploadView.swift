import AUNCoreBridge
import AUNDesign
import SwiftUI
import UniformTypeIdentifiers

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
            TextField(label, text: $text, prompt: Text(prompt)).autocorrectionDisabled()
                .accessibilityIdentifier(identifier)
        }
    }
}

extension View {
    /// List rows on the theme's surface instead of the system's grouped grey.
    func studioRows() -> some View { listRowBackground(Rectangle().fill(Fanous.surface)) }
}

/// Upload one video or many: pick files, set values for all of them, follow the queue.
struct UploadView: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession
    @State private var composer = UploadComposer()
    @State private var importing = false
    #if os(iOS)
        @State private var photoPicks: [PhotosPickerItem] = []
        @State private var loadingPhotos = false
    #endif

    /// Why this account cannot upload at all, from `GET /api/me/creator`: its videos data is pending deletion, or it
    /// has no creator tier (uploads by invitation).
    private var uploadRefusal: Refusal? {
        if let state = session.accountState { return state }
        if let creator = session.creator, !creator.canUpload { return Refusal(code: Refusal.uploadsByInvitation) }
        return nil
    }

    var body: some View {
        Form {
            if let refusal = uploadRefusal {
                // The server would refuse every upload; say why instead of offering the picker.
                Text(l10n(StudioFailure.refusalMessage(refusal).key)).foregroundStyle(Fanous.textSecondary).studioRows()
                    .accessibilityIdentifier("upload-refused")
            } else if let channel = session.channel {
                filesSection.studioRows()
                if !composer.files.isEmpty {
                    SetForAllSection(composer: composer, channel: channel) {
                        Task { await composer.loadPlaylists(channelID: channel.id, studio: session.services.studio) }
                    }
                    sendSection(channel).studioRows()
                }
            } else {
                Text(l10n("studio.channel.none")).foregroundStyle(Fanous.textSecondary).studioRows()
            }
            UploadQueueSection(session: session).studioRows()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fanousPage()
        .navigationTitle(l10n("studio.upload.title"))
        .task {
            let count = SampleVideos.requestedCount()
            guard count > 0, composer.files.isEmpty else { return }
            let samples = await SampleVideos.make(count: count)
            composer.add(samples.compactMap { PickedVideo.make(file: $0, ownsFile: true) })
        }
        .task(id: session.channel?.id) {
            if let channel = session.channel {
                await composer.loadPlaylists(channelID: channel.id, studio: session.services.studio)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
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

    // MARK: Files

    private var filesSection: some View {
        Section {
            ForEach(composer.files) { file in
                FileRow(composer: composer, id: file.id, channelName: session.channel?.displayName(l10n.language) ?? "")
            }
            HStack(spacing: FanousScale.spacingMd) {
                #if os(iOS)
                    PhotosPicker(selection: $photoPicks, matching: .videos, preferredItemEncoding: .current) {
                        Label(l10n("studio.upload.fromPhotos"), systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("upload-photos")
                    if loadingPhotos { ProgressView().accessibilityLabel(l10n("common.loading")) }
                #endif
                Button {
                    importing = true
                } label: {
                    Label(l10n("studio.upload.fromFiles"), systemImage: "folder")
                }
                .accessibilityIdentifier("upload-files")
            }
            .buttonStyle(.borderless)
        } header: {
            Text(l10n("studio.upload.files"))
        } footer: {
            if composer.files.isEmpty {
                #if os(macOS)
                    Text(l10n("studio.upload.empty"))
                #else
                    Text(l10n("studio.upload.emptyMobile"))
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
                Text(l10n("studio.upload.send", composer.files.count.formatted(.number.locale(l10n.language.locale))))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FanousButtonStyle(.primary))
            .disabled(problem != nil)
            .accessibilityIdentifier("upload-send")
            if let problem, !composer.files.isEmpty {
                Text(l10n(problem)).fanousFont(.caption).foregroundStyle(Fanous.errorText)
                    .accessibilityIdentifier("upload-problem")
            }
        } footer: {
            Text(l10n("studio.upload.channelNote", channel.displayName(l10n.language)))
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
            for item in items {
                guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { continue }
                let moved = try? Self.copyIntoContainer(movie.url)
                try? FileManager.default.removeItem(at: movie.url)
                if let moved, let picked = PickedVideo.make(file: moved, ownsFile: true) { composer.add([picked]) }
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
                    prompt: Text(composer.title(at: index, channelName: channelName, language: l10n.language))
                )
                .accessibilityIdentifier("upload-title-\(index)")
                Text(verbatim: "\(file.fileName) · \(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))")
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
                TextField(l10n("studio.upload.titlePattern"), text: $composer.settings.titlePattern)
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
                        composer.settings.firstEpisode.formatted(.number.locale(l10n.language.locale))),
                    value: $composer.settings.firstEpisode, in: 0...9999)
            }
            TextField(l10n("studio.upload.description"), text: $composer.settings.description, axis: .vertical)
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
            Text(l10n(composer.files.count > 1 ? "studio.upload.setForAll" : "studio.upload.details"))
        } footer: {
            Text(l10n("studio.upload.tokensHelp"))
        }
        .studioRows()
        playlistsSection.studioRows()
        scheduleSection.studioRows()
    }

    @ViewBuilder private var playlistsSection: some View {
        Section(l10n("studio.upload.playlists")) {
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
                            (composer.settings.scheduleIntervalMinutes / 60).formatted(.number.locale(l10n.language.locale))),
                        value: $composer.settings.scheduleIntervalMinutes, in: 0...(7 * 24 * 60), step: 60)
                }
            }
        } footer: {
            if composer.scheduleEnabled { Text(l10n("studio.upload.scheduleHelp")) }
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
                ForEach(jobs) { job in UploadJobRow(job: job, queue: session.uploads) }
            } header: {
                HStack {
                    Text(l10n("studio.upload.queue"))
                    Spacer()
                    if jobs.contains(where: { $0.state == .done }) {
                        Button(l10n("studio.upload.clearDone")) { session.uploads.clearFinished() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("upload-clear-done")
                    }
                }
            } footer: {
                #if os(iOS)
                    Text(l10n("studio.upload.backgroundNote"))
                #endif
            }
        }
    }
}

private struct UploadJobRow: View {
    @Environment(\.l10n) private var l10n
    let job: UploadJob
    let queue: UploadQueue

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.title).fanousFont(.body).foregroundStyle(Fanous.textPrimary).lineLimit(2)
                Spacer(minLength: FanousScale.spacingSm)
                actions
            }
            ProgressView(value: job.fraction)
                .accessibilityLabel(l10n("studio.upload.progress", job.title))
                .accessibilityValue(job.fraction.formatted(.percent.precision(.fractionLength(0)).locale(l10n.language.locale)))
            Text(status).fanousFont(.caption)
                .foregroundStyle(job.state == .failed ? Fanous.errorText : Fanous.textSecondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("upload-job-\(job.index)")
    }

    private var status: String {
        switch job.state {
        case .waiting: l10n("studio.upload.state.waiting")
        case .preparing: l10n("studio.upload.state.preparing")
        case .uploading:
            l10n(
                "studio.upload.state.uploading",
                job.fraction.formatted(.percent.precision(.fractionLength(0)).locale(l10n.language.locale)))
        case .finishing: l10n("studio.upload.state.finishing")
        case .paused: l10n("studio.upload.state.paused")
        case .failed: l10n(job.failure ?? "studio.upload.error.generic")
        case .done:
            job.scheduleDate.map {
                l10n("studio.upload.state.scheduled", $0.formatted(.dateTime.locale(l10n.language.locale)))
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
                Button(l10n(job.state == .failed ? "common.retry" : "studio.upload.resume")) { queue.resume(job.id) }
                    .accessibilityIdentifier("upload-resume-\(job.index)")
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

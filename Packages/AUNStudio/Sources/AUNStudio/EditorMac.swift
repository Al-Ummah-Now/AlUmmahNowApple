#if os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import AVFoundation
    import AVKit
    import AppKit
    import SwiftUI
    import UniformTypeIdentifiers

    /// The editor section (E19 19.5): an EDL timeline whose every edit goes through Core, with undo/redo, a preview
    /// and export into the normal upload.
    struct EditorView: View {
        @Environment(\.l10n) private var l10n
        let services: StudioServices
        /// The channel whose brand kit styles titles; nil before a channel is picked (default colours).
        var channelID: String?
        let onUpload: (URL) -> Void

        var body: some View {
            if let edl = services.edl {
                EditorScreen(edl: edl, services: services, channelID: channelID, onUpload: onUpload)
            } else {
                Text(l10n("studio.editor.unavailable")).foregroundStyle(Fanous.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).fanousPage()
            }
        }
    }

    /// Time as m:ss.t in the app's language.
    struct EditorClock {
        let locale: Locale
        func callAsFunction(_ ms: Int) -> String {
            Duration.milliseconds(max(0, ms)).formatted(
                .time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 1)).locale(locale))
        }
    }

    private struct EditorScreen: View {
        @Environment(\.l10n) private var l10n
        @State private var model: EditorModel
        @State private var player = AVPlayer()
        @State private var isPlaying = false
        @State private var pointsPerSecond: CGFloat = 48
        @State private var importing = false
        @State private var confirmingNew = false
        @State private var observer: Any?
        @State private var editingTitle: String?
        let services: StudioServices
        let channelID: String?
        let onUpload: (URL) -> Void
        private let fixtures: Bool

        init(edl: any EDLEditing, services: StudioServices, channelID: String?, onUpload: @escaping (URL) -> Void) {
            self.services = services
            self.channelID = channelID
            let fixtures = UserDefaults.standard.bool(forKey: "AUNUseFixtures")
            let store =
                fixtures
                ? EditorProjectStore(url: FileManager.default.temporaryDirectory.appending(path: "editor-\(UUID()).json"))
                : EditorProjectStore.live()
            _model = State(initialValue: EditorModel(edl: edl, store: store))
            self.fixtures = fixtures
            self.onUpload = onUpload
        }

        private var clock: EditorClock { EditorClock(locale: l10n.language.locale) }

        var body: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
                header
                HStack(alignment: .top, spacing: FanousScale.spacingMd) {
                    previewCard
                    EditorInspector(model: model, clock: clock) { editingTitle = $0 }.frame(width: 280)
                }
                .frame(maxHeight: .infinity)
                EditBar(model: model, pointsPerSecond: $pointsPerSecond) { position in
                    pause()
                    model.addTitle(
                        position: position, text: defaultTitleText(position, brand: model.brand, l10n: l10n),
                        brand: model.brand)
                    if let title = model.selectedTitle { editingTitle = title.titleID }
                }
                if let problem = model.problem { problemBanner(problem) }
                TimelineStrip(
                    model: model, pointsPerSecond: pointsPerSecond, clock: clock,
                    onScrub: { ms in
                        pause()
                        model.playheadMs = ms
                    },
                    onEditTitle: { editingTitle = $0 }
                )
                .frame(height: 196)
                exportBar
            }
            .padding(FanousScale.spacingLg)
            .fanousPage()
            .navigationTitle(l10n("studio.editor.title"))
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await importClips(urls) } }
            }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await importClips(urls) }
                return !urls.isEmpty
            }
            .confirmationDialog(l10n("studio.editor.newProject.confirm"), isPresented: $confirmingNew) {
                Button(l10n("studio.editor.newProject.action"), role: .destructive) {
                    pause()
                    model.newProject()
                }
                Button(l10n("common.cancel"), role: .cancel) {}
            }
            .sheet(
                isPresented: Binding(get: { editingTitle != nil }, set: { if !$0 { editingTitle = nil } })
            ) {
                if let id = editingTitle, let title = model.titles.first(where: { $0.titleID == id }) {
                    TitleTextSheet(model: model, title: title)
                }
            }
            .task(id: channelID) { await loadBrand() }
            .task {
                startObserving()
                if fixtures, model.isEmpty { await seedFixture() }
                await rebuildPreview()
            }
            .onDisappear {
                pause()
                if let observer { player.removeTimeObserver(observer) }
                observer = nil
            }
            .onChange(of: model.timeline) { Task { await rebuildPreview() } }
            .onChange(of: model.playheadMs) { _, ms in if !isPlaying { seek(ms) } }
        }

        // MARK: Header

        private var header: some View {
            HStack(alignment: .firstTextBaseline, spacing: FanousScale.spacingSm) {
                VStack(alignment: .leading, spacing: FanousScale.spacingXxs) {
                    Text(l10n("studio.editor.title")).fanousFont(.title).foregroundStyle(Fanous.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if !model.isEmpty {
                        Text(summary).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                            .accessibilityIdentifier("editor-summary")
                    }
                }
                Spacer()
                Button {
                    model.undo()
                } label: {
                    Label(l10n("studio.editor.undo"), systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                .accessibilityIdentifier("editor-undo")
                Button {
                    model.redo()
                } label: {
                    Label(l10n("studio.editor.redo"), systemImage: "arrow.uturn.forward")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
                .accessibilityIdentifier("editor-redo")
                Button(l10n("studio.editor.newProject")) { confirmingNew = true }
                    .disabled(model.isEmpty && !model.canUndo)
                    .accessibilityIdentifier("editor-new")
                Button {
                    importing = true
                } label: {
                    Label(l10n("studio.editor.import"), systemImage: "plus.rectangle.on.rectangle")
                }
                .accessibilityIdentifier("editor-import")
                Button {
                    pause()
                    model.export(to: exportURL())
                } label: {
                    Label(l10n("studio.editor.export"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(Fanous.primary)
                .disabled(model.isEmpty || isExporting)
                .accessibilityIdentifier("editor-export")
            }
            .controlSize(.large)
        }

        private var summary: String {
            let count = model.clips.count.formatted(.number.locale(l10n.language.locale))
            return "\(l10n("studio.editor.clips", count)) · \(l10n("studio.editor.total", clock(model.timeline.durationMs)))"
        }

        private var isExporting: Bool {
            if case .exporting = model.exportState { return true }
            return false
        }

        // MARK: Preview

        private var previewCard: some View {
            VStack(spacing: 0) {
                ZStack {
                    Rectangle().fill(Fanous.background)
                    if model.isEmpty {
                        emptyState
                    } else {
                        PlayerSurface(player: player).accessibilityHidden(true)
                        TitleOverlay(
                            titles: model.titles(at: model.playheadMs), brand: model.brand, canvas: model.frameSize)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Fanous.divider)
                transport
            }
            .background(Fanous.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Fanous.outline, lineWidth: 1))
        }

        private var emptyState: some View {
            VStack(spacing: FanousScale.spacingSm) {
                Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(Fanous.accent)
                    .accessibilityHidden(true)
                Text(l10n("studio.editor.empty")).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                Text(l10n("studio.editor.emptyHint")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
                Button(l10n("studio.editor.import")) { importing = true }
                    .buttonStyle(.borderedProminent).tint(Fanous.primary)
                    .accessibilityIdentifier("editor-empty-import")
            }
            .padding(FanousScale.spacingLg)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor-empty")
        }

        private var transport: some View {
            HStack(spacing: FanousScale.spacingSm) {
                Button {
                    isPlaying ? pause() : play()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(l10n(isPlaying ? "studio.editor.pause" : "studio.editor.play"))
                .disabled(model.isEmpty)
                .accessibilityIdentifier("editor-play")
                Text(l10n("studio.editor.time", clock(model.playheadMs), clock(model.timeline.durationMs)))
                    .monospacedDigit().fanousFont(.label).foregroundStyle(Fanous.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("editor-time")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, FanousScale.spacingMd)
            .padding(.vertical, FanousScale.spacingSm)
        }

        // MARK: Problem and export

        private func problemBanner(_ key: String) -> some View {
            HStack(spacing: FanousScale.spacingSm) {
                Label(l10n(key), systemImage: "exclamationmark.triangle").foregroundStyle(Fanous.errorText)
                    .fanousFont(.body)
                Spacer()
                Button(l10n("common.dismiss")) { model.clearProblem() }.buttonStyle(.borderless)
            }
            .padding(FanousScale.spacingSm)
            .background(Fanous.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor-problem")
        }

        @ViewBuilder private var exportBar: some View {
            switch model.exportState {
            case .idle:
                EmptyView()
            case .exporting(let fraction):
                let percent = fraction.formatted(.percent.precision(.fractionLength(0)).locale(l10n.language.locale))
                HStack(spacing: FanousScale.spacingSm) {
                    Text(l10n("studio.editor.exportingProgress", percent)).foregroundStyle(Fanous.textSecondary)
                    ProgressView(value: fraction).tint(Fanous.accent).accessibilityLabel(l10n("studio.editor.export"))
                        .accessibilityValue(percent)
                    Button(l10n("common.cancel")) { model.cancelExport() }
                }
                .accessibilityIdentifier("editor-exporting")
            case .finished(let url):
                HStack(spacing: FanousScale.spacingSm) {
                    Label(l10n("studio.editor.exportedTo", url.lastPathComponent), systemImage: "checkmark.circle")
                        .foregroundStyle(Fanous.successText)
                    Spacer()
                    Button(l10n("studio.editor.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button(l10n("studio.editor.uploadExport")) { onUpload(url) }
                        .buttonStyle(.borderedProminent).tint(Fanous.primary)
                        .accessibilityIdentifier("editor-upload-export")
                }
                .accessibilityIdentifier("editor-exported")
            case .failed(let key):
                HStack(spacing: FanousScale.spacingSm) {
                    Label(l10n(key), systemImage: "exclamationmark.triangle").foregroundStyle(Fanous.errorText)
                    Spacer()
                    Button(l10n("common.retry")) { model.export(to: exportURL()) }
                }
            }
        }

        private func exportURL() -> URL {
            fixtures
                ? FileManager.default.temporaryDirectory.appending(path: "editor-export-\(UUID()).mp4")
                : EditorModel.defaultExportURL()
        }

        // MARK: Playback

        private func play() {
            if model.playheadMs >= model.timeline.durationMs { model.playheadMs = 0 }
            seek(model.playheadMs)
            player.play()
            isPlaying = true
        }

        private func pause() {
            player.pause()
            isPlaying = false
        }

        private func seek(_ ms: Int) {
            player.seek(
                to: CMTime(value: CMTimeValue(ms), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        }

        private func startObserving() {
            guard observer == nil else { return }
            let model = model
            let player = player
            observer = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 20), queue: .main
            ) { time in
                MainActor.assumeIsolated {
                    guard player.rate != 0 else { return }
                    model.playheadMs = min(model.timeline.durationMs, Int((time.seconds * 1000).rounded()))
                }
            }
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { isPlaying = false }
            }
        }

        private func rebuildPreview() async {
            guard !model.isEmpty, let built = try? await TimelineComposer.build(model.timeline) else {
                player.replaceCurrentItem(with: nil)
                return
            }
            let item = AVPlayerItem(asset: built.composition)
            item.audioMix = built.audioMix
            player.replaceCurrentItem(with: item)
            seek(model.playheadMs)
            if isPlaying { player.play() }
        }

        // MARK: Brand kit

        /// The channel's kit and logo for new titles and for drawing lower thirds. Without it titles use the server's
        /// default colours, and the inspector says so.
        private func loadBrand() async {
            do {
                let state = try await services.institution.brandKit(channelID: channelID)
                var logo: Data?
                if let id = state.kit.logo {
                    logo = try? await services.institution.assetData(id: id, channelID: channelID)
                }
                model.brand = TitleBrand(kit: state.kit, logo: logo?.isEmpty == false ? logo : nil, fromKit: true)
            } catch {
                AUNLog.studio.info("Editor titles use the default colours; the brand kit did not load: \(error)")
                model.brand = TitleBrand()
            }
        }

        // MARK: Import

        private func importClips(_ urls: [URL]) async {
            for url in urls {
                _ = url.startAccessingSecurityScopedResource()
                do {
                    model.importClip(url: url, media: try await EditorSourceMedia.inspect(url))
                } catch {
                    AUNLog.studio.error("Editor import failed: \(error)")
                    model.importClip(url: url, media: EditorSourceMedia(durationMs: 0))
                }
            }
        }

        /// Fixture runs (UI tests, screenshots): three sample clips, the first cut in two, a title and the kit's lower
        /// third (under the playhead), and the cut's right half selected.
        private func seedFixture() async {
            let urls = await SampleVideos.make(count: 3, seconds: [6, 4, 5])
            await importClips(urls)
            model.playheadMs = 2_500
            model.split()
            let cut = model.selection
            await loadBrand()
            for (position, at) in [(TitlePosition.center, 1_000), (.lowerThird, 7_000)] {
                model.playheadMs = at
                model.addTitle(
                    position: position, text: defaultTitleText(position, brand: model.brand, l10n: l10n), brand: model.brand)
            }
            model.selection = cut
            model.playheadMs = 8_000
        }
    }

    /// AVKit's player view without controls; the editor has its own transport.
    struct PlayerSurface: NSViewRepresentable {
        let player: AVPlayer

        func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.controlsStyle = .none
            view.videoGravity = .resizeAspect
            view.player = player
            return view
        }

        func updateNSView(_ view: AVPlayerView, context: Context) {
            if view.player !== player { view.player = player }
        }
    }

#endif

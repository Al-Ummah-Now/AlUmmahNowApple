#if os(iOS)
    import AUNCoreBridge
    import AUNDesign
    import AVFoundation
    import PhotosUI
    import SwiftUI
    import UniformTypeIdentifiers

    struct PickedMovie: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(contentType: .movie) {
                SentTransferredFile($0.url)
            } importing: { received in
                let copy = FileManager.default.temporaryDirectory.appending(
                    path: "\(UUID().uuidString)-\(received.file.lastPathComponent)")
                try FileManager.default.copyItem(at: received.file, to: copy)
                return PickedMovie(url: copy)
            }
        }
    }

    /// Edit spike on AVFoundation, and the Go Live entry behind its interface.
    public struct StudioIOSRoot: View {
        @Environment(\.l10n) private var l10n
        private let broadcaster: any LiveBroadcasting

        public init(broadcaster: any LiveBroadcasting = UnavailableLiveBroadcaster()) { self.broadcaster = broadcaster }

        public var body: some View {
            TabView {
                NavigationStack { MobileEditorView() }
                    .tabItem { Label(l10n("studio.editor.title"), systemImage: "scissors") }
                NavigationStack {
                    Text(l10n("studio.live.unavailable"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Fanous.textSecondary)
                        .padding()
                        .accessibilityIdentifier("live-unavailable")
                        .navigationTitle(l10n("studio.live.title"))
                }
                .tabItem { Label(l10n("studio.live.title"), systemImage: "dot.radiowaves.left.and.right") }
            }
        }
    }

    struct MobileEditorView: View {
        @Environment(\.l10n) private var l10n
        @State private var list = EditDecisionList()
        @State private var picks: [PhotosPickerItem] = []
        @State private var exporting = false
        @State private var exported: URL?

        var body: some View {
            List {
                ForEach(Array(list.clips.enumerated()), id: \.element.id) { index, clip in
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(Fanous.accentText)
                        Text(DisplayFormat.duration(clip.duration, l10n.language)).monospacedDigit()
                        Spacer()
                        Button {
                            list.move(id: clip.id, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .accessibilityLabel(l10n("studio.editor.moveUp"))
                        Button {
                            list.move(id: clip.id, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .accessibilityLabel(l10n("studio.editor.moveDown"))
                    }
                    .buttonStyle(.borderless)
                    .swipeActions {
                        Button(l10n("studio.editor.delete"), role: .destructive) { list.rippleDelete(id: clip.id) }
                    }
                }
                if list.clips.isEmpty {
                    Text(l10n("studio.editor.empty")).foregroundStyle(Fanous.textSecondary).accessibilityIdentifier(
                        "editor-empty")
                }
                if let exported {
                    ShareLink(item: exported) { Text(l10n("studio.editor.exported")) }
                }
            }
            .navigationTitle(l10n("studio.editor.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $picks, matching: .videos) { Text(l10n("studio.editor.import")) }
                        .accessibilityIdentifier("editor-import")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(l10n(exporting ? "studio.editor.exporting" : "studio.editor.export")) { Task { await export() } }
                        .disabled(list.clips.isEmpty || exporting)
                }
            }
            .onChange(of: picks) { _, items in Task { await load(items) } }
        }

        private func load(_ items: [PhotosPickerItem]) async {
            for item in items {
                guard let movie = try? await item.loadTransferable(type: PickedMovie.self),
                    let duration = try? await AVURLAsset(url: movie.url).load(.duration).seconds
                else { continue }
                list.append(EditClip(source: movie.url, duration: duration))
            }
            picks = []
        }

        private func export() async {
            exporting = true
            defer { exporting = false }
            let output = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
            do {
                try await CompositionBuilder.export(list, to: output)
                exported = output
            } catch {
                AUNLog.studio.error("Export failed: \(error)")
            }
        }
    }
#endif

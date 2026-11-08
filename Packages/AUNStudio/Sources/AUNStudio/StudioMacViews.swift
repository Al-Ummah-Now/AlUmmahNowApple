#if os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import SwiftUI
    import UniformTypeIdentifiers

    enum StudioSection: String, CaseIterable, Identifiable {
        case upload, encode, editor
        var id: String { rawValue }
        var titleKey: String { "studio.\(rawValue).title" }
        var icon: String {
            switch self {
            case .upload: "square.and.arrow.up.on.square"
            case .encode: "cpu"
            case .editor: "timeline.selection"
            }
        }
    }

    /// Studio for Mac: batch upload, encode queue and the editor spike.
    public struct StudioMacRoot: View {
        @Environment(\.l10n) private var l10n
        @State private var section: StudioSection? = .upload
        @State private var uploads: BatchUploadQueue
        @State private var encodes: EncodeQueue

        public init(core: CoreBridge) {
            _uploads = State(
                initialValue: BatchUploadQueue(engine: core.uploads, destinations: SignInRequiredDestinationProvider()))
            _encodes = State(
                initialValue: EncodeQueue(outputDirectory: URL.moviesDirectory.appending(path: "Al Ummah Now Studio")))
        }

        public var body: some View {
            NavigationSplitView {
                List(StudioSection.allCases, selection: $section) { item in
                    Label(l10n(item.titleKey), systemImage: item.icon)
                        .tag(item)
                        .accessibilityIdentifier("section-\(item.rawValue)")
                }
                .navigationSplitViewColumnWidth(min: 170, ideal: 200)
            } detail: {
                switch section ?? .upload {
                case .upload: UploadQueueView(queue: uploads)
                case .encode: EncodeQueueView(queue: encodes)
                case .editor: EditorView()
                }
            }
            .frame(minWidth: 960, minHeight: 600)
        }
    }

    struct UploadQueueView: View {
        @Environment(\.l10n) private var l10n
        let queue: BatchUploadQueue
        @State private var importing = false

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(l10n("studio.upload.title")).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(l10n("studio.upload.add")) { importing = true }.accessibilityIdentifier("upload-add")
                    Button(l10n("studio.upload.start")) { Task { await queue.run() } }
                        .disabled(queue.items.isEmpty || queue.isRunning)
                        .accessibilityIdentifier("upload-start")
                }
                if queue.needsSignIn {
                    Text(l10n("studio.upload.signIn")).foregroundStyle(Fanous.error).accessibilityIdentifier("upload-sign-in")
                }
                if queue.items.isEmpty {
                    Text(l10n("studio.upload.empty")).foregroundStyle(Fanous.textSecondary).frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(queue.items) { item in
                        HStack {
                            Text(item.file.lastPathComponent).lineLimit(1)
                            Spacer()
                            ProgressView(value: item.fraction).frame(width: 120)
                            StatusLabel(status: item.status)
                        }
                    }
                }
            }
            .padding()
            .dropDestination(for: URL.self) { urls, _ in
                queue.add(urls)
                return true
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { queue.add(urls) }
            }
        }
    }

    struct EncodeQueueView: View {
        @Environment(\.l10n) private var l10n
        let queue: EncodeQueue
        @State private var importing = false

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(l10n("studio.encode.title")).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(l10n("studio.encode.add")) { importing = true }
                    Button(l10n("studio.encode.start")) { queue.start() }.disabled(queue.items.isEmpty || queue.isRunning)
                }
                if queue.items.isEmpty {
                    Text(l10n("studio.encode.empty")).foregroundStyle(Fanous.textSecondary).frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(queue.items) { item in
                        HStack {
                            Text(item.source.lastPathComponent).lineLimit(1)
                            Spacer()
                            if let hardware = item.usedHardware {
                                Text(l10n(hardware ? "studio.encode.hardware" : "studio.encode.software")).font(.caption)
                            }
                            ProgressView(value: item.fraction).frame(width: 120)
                            StatusLabel(status: item.status)
                        }
                    }
                }
            }
            .padding()
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { queue.add(urls) }
            }
        }
    }
#endif

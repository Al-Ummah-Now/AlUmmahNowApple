#if os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import SwiftUI
    import UniformTypeIdentifiers

    enum StudioSection: String, CaseIterable, Identifiable {
        case home, content, deleted, upload, analytics, encode, editor
        var id: String { rawValue }
        var titleKey: String { "studio.\(rawValue).title" }
        var icon: String {
            switch self {
            case .home: "square.grid.2x2"
            case .content: "film.stack"
            case .deleted: "trash"
            case .upload: "square.and.arrow.up.on.square"
            case .analytics: "chart.bar"
            case .encode: "cpu"
            case .editor: "timeline.selection"
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

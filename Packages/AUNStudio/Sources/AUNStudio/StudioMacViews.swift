#if os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import SwiftUI
    import UniformTypeIdentifiers

    enum StudioSection: String, CaseIterable, Identifiable {
        case home, content, deleted, upload, captions, analytics, encode, editor
        var id: String { rawValue }
        var titleKey: String { "studio.\(rawValue).title" }

        /// Fixture runs (UI tests, screenshots) can open on a section with `-AUNStudioSection <name>`.
        static func initial(_ defaults: UserDefaults = .standard) -> StudioSection {
            guard defaults.bool(forKey: "AUNUseFixtures") else { return .home }
            return defaults.string(forKey: "AUNStudioSection").flatMap(StudioSection.init(rawValue:)) ?? .home
        }
        var icon: String {
            switch self {
            case .home: "square.grid.2x2"
            case .content: "film.stack"
            case .deleted: "trash"
            case .upload: "square.and.arrow.up.on.square"
            case .captions: "captions.bubble"
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

#if os(macOS)
    import AppKit

    /// Fixture runs only: ⌃⌥⌘S saves every window of the app as a PNG in the app's temporary folder
    /// (`aun-snapshots/`), drawn by the app itself, for reviewing screens where screen capture is not allowed.
    @MainActor
    enum FixtureSnapshots {
        private static var monitor: Any?
        private static var count = 0

        static func installIfFixtures(_ defaults: UserDefaults = .standard) {
            guard monitor == nil, defaults.bool(forKey: "AUNUseFixtures") else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags == [.control, .option, .command], event.charactersIgnoringModifiers == "s" else { return event }
                save()
                return nil
            }
        }

        static func save() {
            let folder = FileManager.default.temporaryDirectory.appending(path: "aun-snapshots")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            count += 1
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = String(format: "%.0f-w%d.png", Date().timeIntervalSince1970 * 1000, index)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: name))
            }
        }
    }
#endif

import AUNCoreBridge
import AUNDesign
import SwiftUI
import UniformTypeIdentifiers

/// Free transcription on this computer (D10): pick or download a whisper model, transcribe the video file with
/// progress and cancel, then send the timed segments to become a draft.
@MainActor @Observable
final class OnDeviceTranscriptionModel {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case transcribing(Double)
        case sending
        case askReplace
        case done
        case failed(String)
    }

    let engine: any OnDeviceTranscribing
    private(set) var models: [TranscriptionModel] = []
    var modelID: String?
    var media: URL?
    private(set) var phase: Phase = .idle
    private var segments: [TranscriptSegment] = []
    private var work: Task<Void, Never>?

    init(engine: any OnDeviceTranscribing) { self.engine = engine }

    var isBusy: Bool {
        switch phase {
        case .downloading, .transcribing, .sending: true
        default: false
        }
    }

    func loadModels() {
        do {
            models = try engine.models()
            if modelID == nil { modelID = models.first(where: \.installed)?.id ?? models.first?.id }
        } catch {
            phase = .failed("studio.captions.onDevice.modelsFailed")
        }
    }

    var selectedModel: TranscriptionModel? { models.first { $0.id == modelID } }

    func download() {
        guard let id = modelID else { return }
        phase = .downloading(0)
        work = Task {
            do {
                try await engine.download(model: id) { fraction in
                    Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(fraction) } }
                }
                loadModels()
                phase = .idle
            } catch is CancellationError {
                phase = .idle
            } catch {
                AUNLog.studio.error("Model download failed: \(error)")
                phase = .failed("studio.captions.onDevice.downloadFailed")
            }
        }
    }

    func transcribe(language: String, captions: CaptionsModel) {
        guard let id = modelID, let media else { return }
        phase = .transcribing(0)
        work = Task {
            let accessing = media.startAccessingSecurityScopedResource()
            defer { if accessing { media.stopAccessingSecurityScopedResource() } }
            do {
                segments = try await engine.transcribe(model: id, media: media, language: language) { fraction in
                    Task { @MainActor in if case .transcribing = self.phase { self.phase = .transcribing(fraction) } }
                }
                guard !segments.isEmpty else {
                    phase = .failed("studio.captions.onDevice.noSpeech")
                    return
                }
                await send(language: language, captions: captions, replace: false)
            } catch is CancellationError {
                phase = .idle
            } catch {
                AUNLog.studio.error("On-device transcription failed: \(error)")
                phase = .failed("studio.captions.onDevice.failed")
            }
        }
    }

    func send(language: String, captions: CaptionsModel, replace: Bool) async {
        phase = .sending
        let transcript = OnDeviceTranscript(
            segments: segments, engine: TranscriptEngine(model: modelID), replace: replace)
        switch await captions.submit(transcript, language: language) {
        case .sent: phase = .done
        case .draftExists: phase = .askReplace
        case .failed: phase = .failed("studio.captions.onDevice.sendFailed")
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
    }
}

struct OnDeviceTranscribeView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    let captions: CaptionsModel
    @State var language: String
    @State private var model: OnDeviceTranscriptionModel?
    @State private var picking = false

    init(captions: CaptionsModel, language: String) {
        self.captions = captions
        _language = State(initialValue: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
            Text(l10n("studio.captions.onDevice.title")).fanousFont(.title).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(l10n("studio.captions.onDevice.body")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let model { form(model) } else { ThemeLoader() }
        }
        .padding(FanousScale.spacingXl)
        .frame(width: 560)
        .fanousPage()
        .onAppear {
            guard model == nil, let engine = captions.services.transcription else { return }
            let created = OnDeviceTranscriptionModel(engine: engine)
            created.loadModels()
            model = created
        }
        .onDisappear { model?.cancel() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.movie, .audio]) { result in
            if case .success(let url) = result { model?.media = url }
        }
    }

    @ViewBuilder private func form(_ model: OnDeviceTranscriptionModel) -> some View {
        @Bindable var model = model
        Picker(l10n("studio.captions.onDevice.model"), selection: $model.modelID) {
            ForEach(model.models) { item in
                Text(
                    l10n(
                        item.installed ? "studio.captions.onDevice.installed" : "studio.captions.onDevice.notInstalled",
                        item.id, ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                )
                .tag(Optional(item.id))
            }
        }
        .disabled(model.isBusy)
        .accessibilityIdentifier("ondevice-model")
        Picker(l10n("studio.captions.jobs.languageLabel"), selection: $language) {
            ForEach(VideoLanguage.allCases, id: \.rawValue) { Text(languageName($0.rawValue, l10n)).tag($0.rawValue) }
        }
        .disabled(model.isBusy)
        HStack {
            Button(l10n("studio.captions.onDevice.pickFile")) { picking = true }
                .disabled(model.isBusy)
                .accessibilityIdentifier("ondevice-pick")
            Text(model.media?.lastPathComponent ?? l10n("studio.captions.onDevice.noFile")).fanousFont(.caption)
                .foregroundStyle(Fanous.textSecondary).lineLimit(1)
        }
        status(model)
        HStack {
            Spacer()
            if model.isBusy {
                Button(l10n("common.cancel")) { model.cancel() }.accessibilityIdentifier("ondevice-cancel")
            } else if model.phase == .done {
                Button(l10n("common.done")) { dismiss() }.buttonStyle(FanousButtonStyle(.primary))
            } else {
                Button(l10n("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                if model.selectedModel?.installed == false {
                    Button(l10n("studio.captions.onDevice.download")) { model.download() }
                        .buttonStyle(FanousButtonStyle(.primary))
                        .accessibilityIdentifier("ondevice-download")
                } else {
                    Button(l10n("studio.captions.onDevice.start")) { model.transcribe(language: language, captions: captions) }
                        .buttonStyle(FanousButtonStyle(.primary))
                        .disabled(model.media == nil || model.selectedModel == nil)
                        .accessibilityIdentifier("ondevice-start")
                }
            }
        }
    }

    @ViewBuilder private func status(_ model: OnDeviceTranscriptionModel) -> some View {
        switch model.phase {
        case .downloading(let fraction):
            ProgressView(l10n("studio.captions.onDevice.downloading"), value: fraction)
        case .transcribing(let fraction):
            ProgressView(l10n("studio.captions.onDevice.transcribing"), value: fraction)
        case .sending:
            ProgressView(l10n("studio.captions.onDevice.sending"))
        case .askReplace:
            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                Text(l10n("studio.captions.jobs.replaceBody", languageName(language, l10n))).fanousFont(.body)
                    .foregroundStyle(Fanous.textPrimary)
                Button(l10n("studio.captions.replace")) {
                    Task { await model.send(language: language, captions: captions, replace: true) }
                }
                .accessibilityIdentifier("ondevice-replace")
            }
        case .done:
            Text(l10n("studio.captions.onDevice.sent")).fanousFont(.body).foregroundStyle(Fanous.successText)
        case .failed(let key):
            Text(l10n(key)).fanousFont(.body).foregroundStyle(Fanous.errorText)
        case .idle:
            EmptyView()
        }
    }
}

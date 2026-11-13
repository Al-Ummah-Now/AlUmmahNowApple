import AUNCoreBridge
import AUNDesign
import AUNPlayer
import SwiftUI

/// One item: player, frame strip (flagged first), reasons and scores, metadata, channel history and the decisions.
/// Everything NSFW or "minor present" is blurred until the audited "Show".
struct ReviewScreen: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.scenePhase) private var phase
    @State private var model: ReviewModel
    @State private var player = PlayerController(subtitleLoader: { _ in "" }, privateMedia: true)
    @State private var sheet: DecisionSheet.Kind?
    let capture: CaptureMonitor
    let isOffline: Bool

    init(model: ReviewModel, capture: CaptureMonitor, isOffline: Bool) {
        _model = State(initialValue: model)
        self.capture = capture
        self.isOffline = isOffline
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ErrorStateView { Task { await model.open() } }
            case .loaded:
                if let detail = model.detail { content(detail) }
            }
        }
        .fanousPage()
        .task { await model.open() }
        .onDisappear {
            model.close()
            player.stop()
        }
        .onChange(of: phase) { _, now in if now != .active { model.hide() } }
        .onChange(of: capture.screenshots) { _, _ in model.hide() }
        .onChange(of: model.detail?.stream) { _, stream in load(stream) }
        .sheet(item: $sheet) { kind in
            DecisionSheet(kind: kind) { reason, note in
                Task { await model.decide(kind == .reject ? .reject : .requestChanges, reason: reason, note: note) }
            }
            .adminPrivacy(capture)
        }
    }

    private func content(_ detail: ReviewDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                header(detail)
                media(detail)
                findings(detail)
                metadata(detail)
                history(detail)
            }
            .padding(FanousScale.spacingLg)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .simultaneousGesture(TapGesture().onEnded { model.interacted() })
        .safeAreaInset(edge: .bottom) {
            ActionBar(model: model, isOffline: isOffline, sheet: $sheet)
        }
    }

    private func header(_ detail: ReviewDetail) -> some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            Text(detail.item.title ?? l10n("admin.item.untitled")).fanousFont(.title).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: FanousScale.spacingSm) {
                if let channel = detail.item.channelName {
                    Text(channel).fanousFont(.label).foregroundStyle(Fanous.textSecondary)
                }
                if detail.item.isOpen { TimeLeft(due: detail.item.slaDueAt) }
            }
            if let other = model.claimedByOther {
                Text(l10n("admin.item.beingReviewed", other.isEmpty ? l10n("admin.item.anotherReviewer") : other))
                    .fanousFont(.label).foregroundStyle(Fanous.accent).accessibilityIdentifier("claimed-by-other")
            }
        }
    }

    @ViewBuilder private func media(_ detail: ReviewDetail) -> some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            ZStack {
                if detail.stream != nil {
                    PlayerSurface(controller: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .blur(radius: model.isBlurred ? 40 : 0, opaque: true)
                        .allowsHitTesting(!model.isBlurred)
                } else {
                    Text(l10n("admin.review.noStream")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                        .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
                        .background(Fanous.surfaceRaised)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            revealControl
            if !detail.frames.isEmpty {
                Text(l10n("admin.review.frames")).fanousFont(.label).foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: FanousScale.spacingSm) {
                        ForEach(detail.frames) { frame in frameView(frame) }
                    }
                }
                .accessibilityIdentifier("frame-strip")
            }
        }
    }

    @ViewBuilder private var revealControl: some View {
        if model.isSensitive {
            HStack {
                if model.isBlurred {
                    Button {
                        Task { await model.reveal() }
                    } label: {
                        Label(l10n("admin.reveal.show"), systemImage: "eye")
                    }
                    .buttonStyle(FanousButtonStyle(.secondary))
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .accessibilityHint(l10n("admin.reveal.hint"))
                    .accessibilityIdentifier("reveal")
                } else {
                    Button {
                        model.hide()
                    } label: {
                        Label(l10n("admin.reveal.hide"), systemImage: "eye.slash")
                    }
                    .buttonStyle(FanousButtonStyle(.ghost))
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .accessibilityIdentifier("hide")
                }
                Text(l10n(model.isBlurred ? "admin.reveal.blurred" : "admin.reveal.audited")).fanousFont(.caption)
                    .foregroundStyle(Fanous.textSecondary)
            }
        }
    }

    private func frameView(_ frame: ReviewFrame) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PrivateImage(reviewID: model.id, key: frame.key, blurred: model.isBlurred, service: model.service)
                .frame(width: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if frame.flagged { RoundedRectangle(cornerRadius: 8).stroke(Fanous.errorText, lineWidth: 3) }
                }
            Text(frameLabel(frame)).fanousFont(.caption).foregroundStyle(Fanous.textSecondary).lineLimit(2)
                .frame(width: 160, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(frameLabel(frame))
    }

    private func frameLabel(_ frame: ReviewFrame) -> String {
        let time = AdminText.timecode(frame.atMs, l10n)
        guard frame.flagged else { return time }
        return l10n("admin.review.flaggedFrame", time, AdminText.category(frame.category ?? "other", l10n))
    }

    private func findings(_ detail: ReviewDetail) -> some View {
        Section {
            ForEach(detail.findings) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(AdminText.category(finding.category, l10n)) · \(AdminText.percent(finding.score, l10n))")
                        .fanousFont(.label).foregroundStyle(Fanous.textPrimary)
                    Text(sourceLine(finding)).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                    if let text = finding.text {
                        Text(text).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                            .blur(radius: model.isBlurred && finding.source == "transcript" ? 6 : 0)
                    }
                    if let rationale = finding.rationale {
                        Text(rationale).fanousFont(.caption).foregroundStyle(Fanous.textMuted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            sectionTitle("admin.review.reasons")
        }
    }

    private func sourceLine(_ finding: ReviewFinding) -> String {
        let source = AdminText.optional("admin.source.\(finding.source)", l10n) ?? finding.source
        guard let at = finding.atMs else { return source }
        return "\(source) · \(AdminText.timecode(at, l10n))"
    }

    @ViewBuilder private func metadata(_ detail: ReviewDetail) -> some View {
        if let subject = detail.subject {
            Section {
                VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                    Text(subject.description.isEmpty ? l10n("admin.review.noDescription") : subject.description)
                        .fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                    if !subject.tags.isEmpty {
                        Text(subject.tags.map { "#\($0)" }.joined(separator: " ")).fanousFont(.caption)
                            .foregroundStyle(Fanous.textSecondary)
                    }
                    if let duration = subject.duration {
                        Text(DisplayFormat.duration(duration, l10n.language)).fanousFont(.caption)
                            .foregroundStyle(Fanous.textMuted)
                    }
                }
            } header: {
                sectionTitle("admin.review.metadata")
            }
        }
    }

    @ViewBuilder private func history(_ detail: ReviewDetail) -> some View {
        Section {
            if detail.history.isEmpty {
                Text(l10n("admin.review.noHistory")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
            }
            ForEach(detail.history) { entry in
                HStack {
                    Text(AdminText.decision(entry.decision ?? entry.status ?? "", by: entry.decidedByName, l10n: l10n))
                    Spacer()
                    if let at = entry.decidedAt {
                        Text(at.formatted(.dateTime.day().month().year().locale(l10n.language.locale)))
                    }
                }
                .fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
            }
        } header: {
            sectionTitle("admin.review.history")
        }
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(l10n(key)).fanousFont(.label).foregroundStyle(Fanous.textPrimary).accessibilityAddTraits(.isHeader)
    }

    private func load(_ stream: ReviewStream?) {
        guard let stream else { return player.stop() }
        player.load(PlaybackItem(url: stream.url, title: ""), autoplay: false)
    }
}

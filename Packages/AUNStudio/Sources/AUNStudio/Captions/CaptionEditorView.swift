import AUNCoreBridge
import AUNDesign
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// The cue editor of one draft: the cue list, the selected cue's text and times, undo/redo, save and publish.
struct CaptionEditorView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State var model: CaptionEditorModel
    let onClose: () -> Void
    /// Where the caret is in each speech segment of the selected cue, for "Split at cursor".
    @State private var caret: [Int: Int] = [:]
    @State private var focusedSegment = 0

    /// Arabic and Urdu drafts are edited right to left whatever the app language.
    private var direction: LayoutDirection { ["ar", "ur", "fa", "he"].contains(model.language) ? .rightToLeft : .leftToRight }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.loadFailed {
                ErrorStateView { Task { await model.load() } }
            } else if model.summary == nil {
                ThemeLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.cues.isEmpty {
                EmptyStateView(title: l10n("studio.captions.editor.empty"), message: "")
            } else {
                HStack(spacing: 0) {
                    cueList.frame(width: 320)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .fanousPage()
        .task { await model.load() }
        // Saves two seconds after the last edit, as the web editor does.
        .task(id: model.editCount) {
            guard model.save == .unsaved else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, model.save == .unsaved { await model.saveNow() }
        }
        .overlay(alignment: .bottom) { MessageBanner(message: $model.message) }
        .sheet(isPresented: $model.confirmReplaceUpload) {
            ConfirmSheet(
                title: l10n("studio.captions.replaceUploadTitle"),
                message: l10n("studio.captions.replaceUploadBody", languageName(model.language, l10n)),
                actionTitle: l10n("studio.captions.replace")
            ) { Task { await model.publish(replaceUpload: true) } }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            HStack(spacing: FanousScale.spacingMd) {
                Text(l10n("studio.captions.editor.title", languageName(model.language, l10n)))
                    .fanousFont(.title).foregroundStyle(Fanous.textPrimary).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(l10n(saveKey)).fanousFont(.caption)
                    .foregroundStyle([.failed, .conflict].contains(model.save) ? Fanous.errorText : Fanous.textSecondary)
                    .accessibilityIdentifier("editor-save-state")
                Button(l10n("studio.captions.editor.undo")) { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                    .accessibilityIdentifier("editor-undo")
                Button(l10n("studio.captions.editor.redo")) { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
                    .accessibilityIdentifier("editor-redo")
                Button(l10n("studio.captions.editor.publishSaved")) { Task { await model.publish() } }
                    .buttonStyle(FanousButtonStyle(.primary))
                    .disabled(model.summary == nil || model.save == .saving || model.save == .conflict)
                    .accessibilityIdentifier("editor-publish")
                Button(l10n("studio.captions.editor.close")) {
                    Task {
                        if model.save == .unsaved { await model.saveNow() }
                        onClose()
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("editor-close")
            }
            Text(l10n("studio.captions.editor.banner")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
            if model.save == .conflict {
                HStack {
                    Text(l10n("studio.captions.conflict")).fanousFont(.body).foregroundStyle(Fanous.errorText)
                    Button(l10n("studio.captions.reload")) { Task { await model.load() } }
                        .accessibilityIdentifier("editor-reload")
                }
            } else if model.save == .failed {
                HStack {
                    Text(l10n("studio.captions.editor.saveFailed")).fanousFont(.body).foregroundStyle(Fanous.errorText)
                    Button(l10n("studio.captions.editor.retry")) { Task { await model.saveNow() } }
                }
            }
        }
        .padding(FanousScale.spacingLg)
        // Save with ⌘S at any time.
        .background {
            Button("") { Task { await model.saveNow() } }
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var saveKey: String {
        switch model.save {
        case .saved: "studio.captions.editor.saved"
        case .saving: "studio.captions.editor.saving"
        case .unsaved: "studio.captions.editor.unsaved"
        case .failed: "studio.captions.editor.saveFailed"
        case .conflict: "studio.captions.editor.unsaved"
        }
    }

    // MARK: Cue list

    private var cueList: some View {
        List(selection: $model.selection) {
            ForEach(Array(model.cues.enumerated()), id: \.element.id) { _, cue in
                VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                    Text("\(CueTime.text(cue.startMs, l10n.language)) – \(CueTime.text(cue.endMs, l10n.language))")
                        .fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(cue.speechText.isEmpty ? l10n("studio.captions.quran.label") : cue.speechText)
                        .fanousFont(.body).foregroundStyle(Fanous.textPrimary).lineLimit(2)
                        .environment(\.layoutDirection, direction)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tag(cue.id)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cue-\(cue.id)")
            }
        }
        .accessibilityLabel(l10n("studio.captions.editor.cueList"))
        .scrollContentBackground(.hidden)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let index = model.selectedIndex {
            let cue = model.cues[index]
            ScrollView {
                VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                    times(cue)
                    ForEach(Array(cue.segments.enumerated()), id: \.offset) { offset, segment in
                        switch segment {
                        case .speech(let text):
                            VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                                Text(l10n("studio.captions.editor.cueText")).fanousFont(.label)
                                    .foregroundStyle(Fanous.textSecondary)
                                CueTextEditor(
                                    text: text, isRightToLeft: direction == .rightToLeft,
                                    accessibilityLabel: l10n("studio.captions.editor.cueText"),
                                    onChange: { model.setText($0, cue: index, segment: offset) },
                                    onCaret: {
                                        caret[offset] = $0
                                        focusedSegment = offset
                                    }
                                )
                                .frame(minHeight: 90)
                                .accessibilityIdentifier("cue-text-\(offset)")
                            }
                        case .quran(let quran):
                            QuranReference(segment: quran)
                        }
                    }
                    actions(cue, index: index)
                }
                .padding(FanousScale.spacingLg)
            }
            .id(cue.id)
        } else {
            EmptyStateView(title: l10n("studio.captions.editor.pick"), message: "")
        }
    }

    private func times(_ cue: CaptionCue) -> some View {
        HStack(spacing: FanousScale.spacingXl) {
            nudger(
                title: l10n("studio.captions.editor.start"), value: cue.startMs, edge: .start,
                earlier: "studio.captions.editor.startEarlier", later: "studio.captions.editor.startLater")
            nudger(
                title: l10n("studio.captions.editor.end"), value: cue.endMs, edge: .end,
                earlier: "studio.captions.editor.endEarlier", later: "studio.captions.editor.endLater")
        }
    }

    private func nudger(title: String, value: Int, edge: CueEditing.Edge, earlier: String, later: String) -> some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            Text(title).fanousFont(.label).foregroundStyle(Fanous.textSecondary)
            // Times read left to right in every language, like the timeline.
            HStack(spacing: FanousScale.spacingSm) {
                Button {
                    model.nudge(edge, by: -CueEditing.nudgeMs)
                } label: {
                    Image(systemName: "minus")
                }
                .accessibilityLabel(l10n(earlier))
                .accessibilityIdentifier("nudge-\(edge == .start ? "start" : "end")-earlier")
                Text(CueTime.text(value, l10n.language)).fanousFont(.body).monospacedDigit()
                    .foregroundStyle(Fanous.textPrimary)
                    .frame(minWidth: 80)
                Button {
                    model.nudge(edge, by: CueEditing.nudgeMs)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(l10n(later))
                .accessibilityIdentifier("nudge-\(edge == .start ? "start" : "end")-later")
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityElement(children: .contain)
    }

    private func actions(_ cue: CaptionCue, index: Int) -> some View {
        HStack(spacing: FanousScale.spacingMd) {
            Button(l10n("studio.captions.editor.split")) {
                let segment = cue.segments.indices.contains(focusedSegment) ? focusedSegment : 0
                let text = cue.segments.indices.contains(segment) ? (cue.segments[segment].speech ?? "") : ""
                model.split(at: caret[segment] ?? text.count / 2, segment: segment)
            }
            .disabled(cue.segments.allSatisfy { $0.speech == nil })
            .accessibilityIdentifier("cue-split")
            Button(l10n("studio.captions.editor.mergeNext")) { model.mergeWithNext() }
                .disabled(index + 1 >= model.cues.count)
                .accessibilityIdentifier("cue-merge")
            Spacer()
            Button(role: .destructive) {
                model.deleteSelected()
            } label: {
                Text(l10n("studio.captions.editor.deleteCue")).foregroundStyle(Fanous.errorText)
            }
            .accessibilityIdentifier("cue-delete")
        }
        .buttonStyle(FanousButtonStyle(.secondary))
    }
}

/// A Quran reference in a cue. Studio shows it as a reference; confirming suggestions stays on the web editor.
struct QuranReference: View {
    @Environment(\.l10n) private var l10n
    let segment: CaptionQuranSegment

    var body: some View {
        HStack(spacing: FanousScale.spacingSm) {
            Image(systemName: "book.closed").foregroundStyle(Fanous.accent).accessibilityHidden(true)
            Text(l10n("studio.captions.quran.label")).fanousFont(.label).foregroundStyle(Fanous.textPrimary)
            Text(segment.range).fanousFont(.body).monospacedDigit().foregroundStyle(Fanous.textPrimary)
                .environment(\.layoutDirection, .leftToRight)
            StatusChip(text: l10n(statusKey), emphasised: ["confirmed", "accepted"].contains(segment.status))
        }
        .padding(FanousScale.spacingMd)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fanousMaterial(.raised) { .rounded($0.md) }
        .accessibilityElement(children: .combine)
    }

    private var statusKey: String {
        switch segment.status {
        case "confirmed", "accepted": "studio.captions.quran.confirmed"
        case "basmala": "studio.captions.quran.basmala"
        case "context": "studio.captions.quran.possible"
        default: "studio.captions.quran.suggested"
        }
    }
}

/// `m:ss.t` (or `h:mm:ss.t`) in the app's digits.
enum CueTime {
    static func text(_ ms: Int, _ language: AppLanguage) -> String {
        let tenths = (ms % 1000) / 100
        let digit = tenths.formatted(.number.locale(language.locale))
        let separator = language == .ar ? "٫" : "."
        return DisplayFormat.duration(Double(ms / 1000), language) + separator + digit
    }
}

#if os(macOS)
    /// A text view that reports the caret, so a cue can be split where the creator clicked. Arabic is written right to
    /// left with the system's bidi handling.
    struct CueTextEditor: NSViewRepresentable {
        let text: String
        let isRightToLeft: Bool
        let accessibilityLabel: String
        let onChange: (String) -> Void
        let onCaret: (Int) -> Void

        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: CueTextEditor
            init(_ parent: CueTextEditor) { self.parent = parent }

            func textDidChange(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                parent.onChange(view.string)
            }

            func textViewDidChangeSelection(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                let location = view.selectedRange().location
                // Characters, not UTF-16 units, as the split counts them.
                let prefix = (view.string as NSString).substring(to: min(location, (view.string as NSString).length))
                parent.onCaret(prefix.count)
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSTextView.scrollableTextView()
            guard let view = scroll.documentView as? NSTextView else { return scroll }
            view.delegate = context.coordinator
            view.isRichText = false
            view.allowsUndo = false
            view.font = NSFont.preferredFont(forTextStyle: .body)
            view.textColor = NSColor.textColor
            view.drawsBackground = false
            view.string = text
            view.setAccessibilityLabel(accessibilityLabel)
            apply(direction: view)
            scroll.drawsBackground = false
            scroll.borderType = .bezelBorder
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            context.coordinator.parent = self
            guard let view = scroll.documentView as? NSTextView else { return }
            if view.string != text {
                let selection = view.selectedRange()
                view.string = text
                view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            }
            apply(direction: view)
        }

        private func apply(direction view: NSTextView) {
            view.baseWritingDirection = isRightToLeft ? .rightToLeft : .leftToRight
            view.alignment = isRightToLeft ? .right : .left
        }
    }
#else
    struct CueTextEditor: View {
        let text: String
        let isRightToLeft: Bool
        let accessibilityLabel: String
        let onChange: (String) -> Void
        let onCaret: (Int) -> Void
        @State private var value = ""

        var body: some View {
            TextEditor(text: $value)
                .environment(\.layoutDirection, isRightToLeft ? .rightToLeft : .leftToRight)
                .accessibilityLabel(accessibilityLabel)
                .onAppear { value = text }
                .onChange(of: value) { _, new in if new != text { onChange(new) } }
        }
    }
#endif

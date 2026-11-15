#if os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import AppKit
    import SwiftUI

    /// The edit buttons, each with a keyboard shortcut, so every edit works without a mouse.
    struct EditBar: View {
        @Environment(\.l10n) private var l10n
        let model: EditorModel
        @Binding var pointsPerSecond: CGFloat

        var body: some View {
            HStack(spacing: FanousScale.spacingXs) {
                tool("studio.editor.split", "scissors", "editor-split", key: "s") { model.split() }
                    .disabled(model.clipAtPlayhead == nil)
                tool("studio.editor.trimStart", "arrow.right.to.line", "editor-trim-start", key: "[") {
                    model.trimSelectionToPlayhead(start: true)
                }
                .disabled(model.selectedClip == nil)
                tool("studio.editor.trimEnd", "arrow.left.to.line", "editor-trim-end", key: "]") {
                    model.trimSelectionToPlayhead(start: false)
                }
                .disabled(model.selectedClip == nil)
                tool("studio.editor.join", "link", "editor-join", key: "j") {
                    model.joinWithNext()
                }
                .disabled(model.nextAfterSelection == nil)
                tool("studio.editor.delete", "delete.left", "editor-delete", key: .delete) {
                    model.rippleDelete()
                }
                .disabled(model.selectedClip == nil)
                Divider().frame(height: 20)
                tool("studio.editor.earlier", "chevron.left.2", "editor-earlier", key: .leftArrow, modifiers: .option) {
                    if let id = model.selection { model.nudge(id, by: -EditorModel.nudgeMs) }
                }
                .disabled(model.selectedClip == nil)
                tool("studio.editor.later", "chevron.right.2", "editor-later", key: .rightArrow, modifiers: .option) {
                    if let id = model.selection { model.nudge(id, by: EditorModel.nudgeMs) }
                }
                .disabled(model.selectedClip == nil)
                Spacer()
                Button {
                    pointsPerSecond = max(12, pointsPerSecond / 1.5)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)
                .accessibilityLabel(l10n("studio.editor.zoomOut"))
                .help(l10n("studio.editor.zoomOut"))
                Button {
                    pointsPerSecond = min(240, pointsPerSecond * 1.5)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("=", modifiers: .command)
                .accessibilityLabel(l10n("studio.editor.zoomIn"))
                .help(l10n("studio.editor.zoomIn"))
            }
            .buttonStyle(.bordered)
            .disabled(model.isEmpty)
        }

        /// Tools whose tooltip says more than their title.
        static let withHelp: Set = [
            "studio.editor.trimStart", "studio.editor.trimEnd", "studio.editor.join", "studio.editor.delete",
        ]

        private func tool(
            _ key: String, _ symbol: String, _ identifier: String, key shortcut: KeyEquivalent,
            modifiers: EventModifiers = [], action: @escaping () -> Void
        ) -> some View {
            Button(action: action) { Label(l10n(key), systemImage: symbol) }
                .keyboardShortcut(shortcut, modifiers: modifiers)
                .help(l10n(Self.withHelp.contains(key) ? "\(key).help" : key))
                .accessibilityIdentifier(identifier)
        }
    }

    /// The selected clip's facts, or how to pick one.
    struct EditorInspector: View {
        @Environment(\.l10n) private var l10n
        let model: EditorModel
        let clock: EditorClock

        var body: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                Text(l10n("studio.editor.selected")).fanousFont(.label).foregroundStyle(Fanous.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                if let clip = model.selectedClip {
                    Text(model.sourceNames[clip.sourceID] ?? clip.sourceID)
                        .fanousFont(.headline).foregroundStyle(Fanous.textPrimary).lineLimit(2)
                    fact("clock", l10n("studio.editor.position", clock(clip.timelineStartMs)))
                    fact("timer", l10n("studio.editor.length", clock(clip.timelineDurationMs)))
                    fact("film", l10n("studio.editor.range", clock(clip.inMs), clock(clip.outMs)))
                } else {
                    Text(l10n(model.isEmpty ? "studio.editor.empty" : "studio.editor.noSelection"))
                        .fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(FanousScale.spacingMd)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Fanous.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Fanous.outline, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor-inspector")
        }

        private func fact(_ symbol: String, _ text: String) -> some View {
            Label(text, systemImage: symbol).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
        }
    }
#endif

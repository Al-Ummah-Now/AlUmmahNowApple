#if os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import AppKit
    import SwiftUI

    typealias EditorTitle = FlattenedTimeline.Title
    typealias TitlePosition = FlattenedTimeline.TitleStyle.Position

    /// Rendered title images, so the preview redraws a title only when it or the kit changes.
    @MainActor
    final class TitleImageCache {
        static let shared = TitleImageCache()
        private struct Key: Hashable {
            let title: EditorTitle
            let brand: TitleBrand
            let width: Int
            let height: Int
        }
        private var images: [Key: CGImage] = [:]

        func image(_ title: EditorTitle, brand: TitleBrand, canvas: CGSize) -> CGImage? {
            let key = Key(title: title, brand: brand, width: Int(canvas.width), height: Int(canvas.height))
            if let image = images[key] { return image }
            guard let image = TitleRenderer.image(title, brand: brand, canvas: canvas) else { return nil }
            if images.count > 48 { images.removeAll() }
            images[key] = image
            return image
        }
    }

    /// The titles on screen at the playhead, drawn over the preview with the export's images.
    struct TitleOverlay: View {
        let titles: [EditorTitle]
        let brand: TitleBrand
        let canvas: CGSize

        var body: some View {
            ZStack {
                ForEach(titles) { title in
                    if let image = TitleImageCache.shared.image(title, brand: brand, canvas: canvas) {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    }
                }
            }
            .aspectRatio(canvas.width / max(canvas.height, 1), contentMode: .fit)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    extension TitlePosition {
        var labelKey: String {
            switch self {
            case .top: "studio.editor.titles.position.top"
            case .center: "studio.editor.titles.position.center"
            case .lowerThird: "studio.editor.titles.position.lowerThird"
            }
        }
    }

    /// The selected title's text, place, timing and kit style.
    struct TitleInspector: View {
        @Environment(\.l10n) private var l10n
        let model: EditorModel
        let title: EditorTitle
        let clock: EditorClock
        let onEditText: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                Text(l10n(title.style.position == .lowerThird ? "studio.editor.titles.lowerThird" : "studio.editor.titles.title"))
                    .fanousFont(.label).foregroundStyle(Fanous.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(title.lines, id: \.locale) { line in
                    Text(line.text)
                        .fanousFont(.headline).foregroundStyle(Fanous.textPrimary).lineLimit(2)
                        .environment(\.layoutDirection, TitleRenderer.isRightToLeft(line.locale) ? .rightToLeft : .leftToRight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(l10n("studio.editor.titles.editText"), action: onEditText)
                    .accessibilityIdentifier("title-edit-text")
                Picker(
                    l10n("studio.editor.titles.position"),
                    selection: Binding(
                        get: { title.style.position },
                        set: { model.setTitlePosition(title.titleID, $0, brand: model.brand) })
                ) {
                    ForEach(TitlePosition.allCases, id: \.self) { Text(l10n($0.labelKey)).tag($0) }
                }
                .accessibilityIdentifier("title-position")
                Label(l10n("studio.editor.position", clock(title.startMs)), systemImage: "clock")
                Label(l10n("studio.editor.length", clock(title.durationMs)), systemImage: "timer")
                HStack(spacing: FanousScale.spacingXs) {
                    Button(l10n("studio.editor.titles.shorter")) {
                        model.resizeTitle(title.titleID, by: -EditorModel.nudgeMs / 2)
                    }
                    .disabled(title.durationMs <= EditorModel.minTitleMs)
                    .accessibilityIdentifier("title-shorter")
                    Button(l10n("studio.editor.titles.longer")) {
                        model.resizeTitle(title.titleID, by: EditorModel.nudgeMs / 2)
                    }
                    .accessibilityIdentifier("title-longer")
                }
                Button(l10n("studio.editor.titles.toPlayhead")) { model.moveTitle(title.titleID, toMs: model.playheadMs) }
                    .accessibilityIdentifier("title-to-playhead")
                Button(l10n("studio.editor.titles.applyBrand")) { model.applyBrand(title.titleID, brand: model.brand) }
                    .disabled(model.brand.style(for: title.style.position) == title.style)
                    .help(l10n("studio.editor.titles.applyBrand.help"))
                    .accessibilityIdentifier("title-apply-brand")
                Text(l10n(model.brand.fromKit ? "studio.editor.titles.styledByKit" : "studio.editor.titles.styledByDefault"))
                    .fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fanousFont(.body)
            .foregroundStyle(Fanous.textPrimary)
        }
    }

    /// Edits a title's English and Arabic lines. A title needs at least one; each field keeps its script's side.
    struct TitleTextSheet: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.dismiss) private var dismiss
        let model: EditorModel
        let title: EditorTitle
        @State private var english: String
        @State private var arabic: String

        init(model: EditorModel, title: EditorTitle) {
            self.model = model
            self.title = title
            _english = State(initialValue: title.text["en"] ?? "")
            _arabic = State(initialValue: title.text["ar"] ?? "")
        }

        private var isBlank: Bool {
            english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && arabic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var body: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
                Text(l10n("studio.editor.titles.editText")).fanousFont(.title).foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(l10n("studio.editor.titles.textHint")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                field(l10n("studio.editor.titles.textEn"), $english, alignment: .leading, id: "title-text-en")
                field(l10n("studio.editor.titles.textAr"), $arabic, alignment: .trailing, id: "title-text-ar")
                if isBlank {
                    Text(l10n("studio.editor.titles.error.text")).fanousFont(.caption).foregroundStyle(Fanous.errorText)
                }
                HStack {
                    Spacer()
                    Button(l10n("common.cancel"), role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(l10n("studio.editor.titles.save")) {
                        var text = title.text
                        text["en"] = english
                        text["ar"] = arabic
                        model.setTitleText(title.titleID, text: text)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Fanous.primary)
                    .disabled(isBlank)
                    .accessibilityIdentifier("title-save")
                }
            }
            .padding(FanousScale.spacingLg)
            .frame(width: 460)
            .background(Fanous.surface)
        }

        private func field(_ label: String, _ text: Binding<String>, alignment: TextAlignment, id: String) -> some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                Text(label).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                // Like the brand kit's name fields: laid out left to right, the Arabic field right-aligned, so each
                // keeps its own script's side whatever the app language is.
                TextField(label, text: text)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(alignment)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier(id)
            }
        }
    }

    /// Default text for a new title: the kit's name on a lower third, else a placeholder in the app language.
    @MainActor
    func defaultTitleText(_ position: TitlePosition, brand: TitleBrand, l10n: L10n) -> [String: String] {
        if position == .lowerThird {
            let names = ["en": brand.kit.name.en ?? "", "ar": brand.kit.name.ar ?? ""]
                .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            if !names.isEmpty { return names }
        }
        return [l10n.language == .ar ? "ar" : "en": l10n("studio.editor.titles.placeholder")]
    }
#endif

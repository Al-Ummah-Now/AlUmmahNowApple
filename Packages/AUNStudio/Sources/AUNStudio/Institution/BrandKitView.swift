import AUNCoreBridge
import AUNDesign
import SwiftUI

/// A kit colour (`#rrggbb`, the creator's own data) as a SwiftUI colour.
func brandColor(_ hex: String) -> Color {
    guard BrandKit.isValidColor(hex), let value = UInt32(hex.dropFirst(), radix: 16) else { return .clear }
    return Color(
        .sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255)
}

/// `#rrggbb` for a picked colour.
func brandHex(_ color: Color) -> String {
    let resolved = color.resolve(in: EnvironmentValues())
    func byte(_ value: Float) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", byte(resolved.red), byte(resolved.green), byte(resolved.blue))
}

/// The brand kit editor: names, colours, logo/intro/outro from the asset library, lower third and watermark, with a
/// preview of how titles look. Read-only for team members.
struct BrandKitView: View {
    @Environment(\.l10n) private var l10n
    @State private var model: InstitutionModel

    init(services: StudioServices, channelID: String) {
        _model = State(initialValue: InstitutionModel(services: services, channelID: channelID))
    }

    var body: some View {
        Group {
            switch model.load {
            case .loading: ThemeLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed: ErrorStateView { Task { await model.refresh() } }
            case .loaded: editor
            }
        }
        .fanousPage()
        .navigationTitle(l10n("studio.brand.title"))
        .task { await model.refresh() }
        .overlay(alignment: .bottom) { MessageBanner(message: $model.message) }
    }

    /// Save and discard sit on the page, next to what they change.
    private var actions: some View {
        HStack(spacing: FanousScale.spacingMd) {
            Text(l10n(model.hasChanges ? "studio.brand.unsaved" : "studio.brand.upToDate"))
                .fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
            Spacer()
            Button(l10n("studio.brand.revert")) { model.revert() }
                .buttonStyle(FanousButtonStyle(.ghost))
                .disabled(!model.hasChanges || model.busy)
                .accessibilityIdentifier("brand-revert")
            Button(l10n("studio.brand.save")) { Task { await model.save() } }
                .buttonStyle(FanousButtonStyle(.primary))
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSave)
                .accessibilityIdentifier("brand-save")
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                if !model.canEdit {
                    Label(l10n("studio.brand.readOnly"), systemImage: "lock")
                        .fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                        .padding(FanousScale.spacingMd)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fanousMaterial(.card) { .rounded($0.md) }
                        .accessibilityIdentifier("brand-read-only")
                }
                if model.canEdit { actions }
                // The Mac window's minimum width always leaves room for both columns.
                HStack(alignment: .top, spacing: FanousScale.spacingLg) {
                    BrandKitFields(model: model).frame(minWidth: 340, idealWidth: 380, maxWidth: 480)
                    BrandPreview(model: model).frame(minWidth: 300, idealWidth: 360)
                }
            }
            .padding(FanousScale.spacingLg)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// Each part of the form is its own view: one body holding the whole form overflowed the main thread's stack in debug
// builds (SwiftUI builds the nested view type inline).

/// The brand kit fields, disabled for team members.
struct BrandKitFields: View {
    @Environment(\.l10n) private var l10n
    let model: InstitutionModel

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
            BrandCard(title: l10n("studio.brand.name")) { BrandNameFields(model: model) }
            BrandCard(title: l10n("studio.brand.colors")) {
                BrandColorRow(model: model, name: "primary", key: \.primary)
                BrandColorRow(model: model, name: "secondary", key: \.secondary)
                BrandColorRow(model: model, name: "text", key: \.text)
                BrandColorRow(model: model, name: "background", key: \.background)
            }
            BrandCard(title: l10n("studio.brand.media")) { BrandMediaFields(model: model) }
            BrandCard(title: l10n("studio.brand.lowerThird")) { BrandLowerThirdFields(model: model) }
        }
        .disabled(!model.canEdit)
    }
}

struct BrandCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            Text(title).fanousFont(.headline).foregroundStyle(Fanous.textPrimary).accessibilityAddTraits(.isHeader)
            content
        }
        .textFieldStyle(.roundedBorder)
        .padding(FanousScale.spacingLg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fanousMaterial(.card) { .rounded($0.lg) }
    }
}

struct BrandNameFields: View {
    @Environment(\.l10n) private var l10n
    let model: InstitutionModel

    var body: some View {
        // Each field keeps its own script's side whatever the app language is: the macOS field ignores the layout
        // direction for alignment, so both are laid out left to right and the Arabic one is right-aligned.
        field(l10n("studio.brand.nameEn"), \.en, alignment: .leading, id: "brand-name-en")
        field(l10n("studio.brand.nameAr"), \.ar, alignment: .trailing, id: "brand-name-ar")
    }

    private func field(
        _ title: String, _ key: WritableKeyPath<BrandKit.Name, String?>, alignment: TextAlignment, id: String
    ) -> some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            Text(title).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
            TextField(
                title, text: Binding(get: { model.kit.name[keyPath: key] ?? "" }, set: { model.kit.name[keyPath: key] = $0 })
            )
            .labelsHidden()
            .multilineTextAlignment(alignment)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
        }
    }
}

struct BrandColorRow: View {
    @Environment(\.l10n) private var l10n
    let model: InstitutionModel
    let name: String
    let key: WritableKeyPath<BrandKit.Colors, String>

    var body: some View {
        let label = l10n("studio.brand.color.\(name)")
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: FanousScale.spacingMd) {
                Text(label).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                    .frame(width: 110, alignment: .leading)
                    .accessibilityHidden(true)
                ColorPicker(
                    label,
                    selection: Binding(
                        get: { brandColor(model.kit.colors[keyPath: key]) },
                        set: { model.kit.colors[keyPath: key] = brandHex($0) }),
                    supportsOpacity: false
                )
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityIdentifier("brand-color-\(name)")
                TextField(
                    label, text: Binding(get: { model.kit.colors[keyPath: key] }, set: { model.kit.colors[keyPath: key] = $0 })
                )
                .labelsHidden()
                .frame(width: 96)
                .environment(\.layoutDirection, .leftToRight)
                .fontDesign(.monospaced)
                .accessibilityLabel(l10n("studio.brand.colorHex", label))
                .accessibilityIdentifier("brand-hex-\(name)")
            }
            if model.invalidColors.contains(name) {
                Text(l10n("studio.brand.colorInvalid")).fanousFont(.caption).foregroundStyle(Fanous.errorText)
            }
        }
    }
}

struct BrandMediaFields: View {
    @Environment(\.l10n) private var l10n
    let model: InstitutionModel

    var body: some View {
        picker(l10n("studio.brand.logo"), kind: .image, slot: \.logo, id: "brand-logo")
        picker(l10n("studio.brand.intro"), kind: .video, slot: \.intro, id: "brand-intro")
        picker(l10n("studio.brand.outro"), kind: .video, slot: \.outro, id: "brand-outro")
        Text(l10n("studio.brand.mediaHint")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
    }

    private func picker(_ title: String, kind: StudioAsset.Kind, slot: WritableKeyPath<BrandKit, String?>, id: String)
        -> some View
    {
        Picker(title, selection: Binding(get: { model.kit[keyPath: slot] }, set: { model.kit[keyPath: slot] = $0 })) {
            Text(l10n("studio.brand.none")).tag(String?.none)
            ForEach(model.assets(of: kind)) { asset in Text(asset.name).tag(Optional(asset.id)) }
        }
        .accessibilityIdentifier(id)
    }
}

struct BrandLowerThirdFields: View {
    @Environment(\.l10n) private var l10n
    @Bindable var model: InstitutionModel

    var body: some View {
        Picker(l10n("studio.brand.style"), selection: $model.kit.lowerThird.style) {
            ForEach(BrandKit.LowerThirdStyle.allCases, id: \.self) { Text(l10n("studio.brand.style.\($0.rawValue)")).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("brand-style")
        Picker(l10n("studio.brand.position"), selection: $model.kit.lowerThird.position) {
            ForEach(BrandKit.LowerThirdPosition.allCases, id: \.self) {
                Text(l10n("studio.brand.position.\($0.rawValue)")).tag($0)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("brand-position")
        Picker(l10n("studio.brand.watermark"), selection: $model.kit.watermark) {
            ForEach(BrandKit.Watermark.allCases, id: \.self) { Text(l10n("studio.brand.watermark.\($0.rawValue)")).tag($0) }
        }
        .accessibilityIdentifier("brand-watermark")
    }
}

/// How the kit looks on a frame: the lower third with the channel name, and the watermark in its corner.
struct BrandPreview: View {
    @Environment(\.l10n) private var l10n
    let model: InstitutionModel
    @State private var logo: Image?

    private var kit: BrandKit { model.kit }

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            Text(l10n("studio.brand.preview")).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ZStack {
                Rectangle().fill(brandColor(kit.colors.background))
                LinearGradient(
                    colors: [brandColor(kit.colors.secondary).opacity(0.0), brandColor(kit.colors.secondary).opacity(0.6)],
                    startPoint: .top, endPoint: .bottom)
                Image(systemName: "play.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(brandColor(kit.colors.text).opacity(0.35))
                watermark
                lowerThird
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Fanous.outline, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(l10n("studio.brand.preview"))
            .accessibilityValue(previewDescription)
            .accessibilityIdentifier("brand-preview")
            Text(l10n("studio.brand.previewHint")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
        }
        .padding(FanousScale.spacingLg)
        .fanousMaterial(.card) { .rounded($0.lg) }
        .task(id: kit.logo) { await loadLogo() }
    }

    private var name: String { kit.displayName(l10n.language) ?? l10n("studio.brand.namePlaceholder") }

    private var previewDescription: String {
        l10n(
            "studio.brand.previewValue", name, l10n("studio.brand.style.\(kit.lowerThird.style.rawValue)"),
            l10n("studio.brand.position.\(kit.lowerThird.position.rawValue)"),
            l10n("studio.brand.watermark.\(kit.watermark.rawValue)"))
    }

    @ViewBuilder private var logoMark: some View {
        if let logo {
            logo.resizable().scaledToFit()
        } else {
            Text(String(name.prefix(1)))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(brandColor(kit.colors.secondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Circle().fill(brandColor(kit.colors.primary)))
        }
    }

    @ViewBuilder private var watermark: some View {
        if kit.watermark != .none {
            let alignment: Alignment =
                switch kit.watermark {
                case .topStart: .topLeading
                case .topEnd: .topTrailing
                case .bottomStart: .bottomLeading
                default: .bottomTrailing
                }
            logoMark
                .frame(width: 36, height: 36)
                .opacity(0.8)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }

    private var lowerThird: some View {
        let style = kit.lowerThird.style
        let alignment: HorizontalAlignment =
            switch kit.lowerThird.position {
            case .start: .leading
            case .center: .center
            case .end: .trailing
            }
        let frameAlignment = Alignment(horizontal: alignment, vertical: .bottom)
        return VStack(alignment: alignment, spacing: 2) {
            Text(name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            Text(l10n("studio.brand.previewSubtitle")).font(.system(size: 12)).opacity(0.85).lineLimit(1)
        }
        .foregroundStyle(brandColor(style == .minimal ? kit.colors.text : kit.colors.text))
        .padding(.horizontal, style == .minimal ? 0 : 14)
        .padding(.vertical, style == .minimal ? 0 : 8)
        .background {
            switch style {
            case .bar:
                Rectangle().fill(brandColor(kit.colors.secondary).opacity(0.92))
                    .overlay(alignment: .leading) { Rectangle().fill(brandColor(kit.colors.primary)).frame(width: 4) }
            case .box: RoundedRectangle(cornerRadius: 8).fill(brandColor(kit.colors.primary).opacity(0.92))
            case .minimal:
                Rectangle().fill(brandColor(kit.colors.primary)).frame(height: 2).frame(maxHeight: .infinity, alignment: .bottom)
                    .offset(y: 6)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
    }

    private func loadLogo() async {
        guard let id = kit.logo else {
            logo = nil
            return
        }
        guard let data = try? await model.services.institution.assetData(id: id, channelID: model.channelID) else { return }
        #if os(macOS)
            logo = NSImage(data: data).map(Image.init(nsImage:))
        #else
            logo = UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

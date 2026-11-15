import AUNCoreBridge
import AUNDesign
import SwiftUI
import UniformTypeIdentifiers

/// The account's shared files (logos, intros, outros, music) for the brand kit and the editor. Owner adds and deletes;
/// team members see the list.
struct AssetLibraryView: View {
    @Environment(\.l10n) private var l10n
    @State private var model: InstitutionModel
    @State private var importing = false
    @State private var deleting: StudioAsset?

    init(services: StudioServices, channelID: String) {
        _model = State(initialValue: InstitutionModel(services: services, channelID: channelID))
    }

    /// What the server accepts (it checks the bytes too).
    static let types: [UTType] = [.png, .jpeg, .webP, .mpeg4Movie, .quickTimeMovie, .mp3, .mpeg4Audio, .wav]

    var body: some View {
        Group {
            switch model.load {
            case .loading: ThemeLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed: ErrorStateView { Task { await model.refresh() } }
            case .loaded: content
            }
        }
        .fanousPage()
        .navigationTitle(l10n("studio.assets.title"))
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.types) { result in
            if case .success(let url) = result { Task { await model.add(file: url) } }
        }
        .sheet(item: $deleting) { asset in
            ConfirmSheet(
                title: l10n("studio.assets.deleteTitle"), message: l10n("studio.assets.deleteBody", asset.name),
                actionTitle: l10n("studio.assets.delete")
            ) { Task { await model.delete(asset) } }
        }
        .task { await model.refresh() }
        .overlay(alignment: .bottom) { MessageBanner(message: $model.message) }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                HStack(alignment: .top, spacing: FanousScale.spacingMd) {
                    usage
                    if model.library.canEdit {
                        Button {
                            importing = true
                        } label: {
                            Label(l10n("studio.assets.add"), systemImage: "plus")
                        }
                        .buttonStyle(FanousButtonStyle(.primary))
                        .disabled(model.uploading != nil)
                        .accessibilityIdentifier("assets-add")
                    }
                }
                if !model.library.canEdit {
                    Label(l10n("studio.assets.readOnly"), systemImage: "lock")
                        .fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                        .accessibilityIdentifier("assets-read-only")
                }
                if let name = model.uploading {
                    HStack(spacing: FanousScale.spacingSm) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(l10n("studio.assets.uploading", name)).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if model.library.assets.isEmpty {
                    EmptyStateView(title: l10n("studio.assets.empty"), message: l10n("studio.assets.emptyMessage"))
                        .frame(minHeight: 240)
                } else {
                    ForEach(StudioAsset.Kind.allCases, id: \.self) { kind in
                        let items = model.assets(of: kind)
                        if !items.isEmpty { group(kind, items) }
                    }
                }
            }
            .padding(FanousScale.spacingLg)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var usage: some View {
        let library = model.library
        let language = l10n.language
        let bytes = ByteCountFormatStyle(style: .memory, locale: language.locale)
        return VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            ProgressView(value: Double(library.bytes), total: Double(max(library.limits.maxTotalBytes, 1)))
                .accessibilityHidden(true)
            Text(
                l10n(
                    "studio.assets.usage", library.bytes.formatted(bytes), library.limits.maxTotalBytes.formatted(bytes),
                    library.assets.count.formatted(.number.locale(language.locale)),
                    library.limits.maxAssets.formatted(.number.locale(language.locale)))
            )
            .fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
            Text(l10n("studio.assets.limits", library.limits.maxAssetBytes.formatted(bytes)))
                .fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
        }
        .padding(FanousScale.spacingMd)
        .fanousMaterial(.card) { .rounded($0.md) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assets-usage")
    }

    private func group(_ kind: StudioAsset.Kind, _ items: [StudioAsset]) -> some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            Text(l10n("studio.assets.kind.\(kind.rawValue)")).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200), spacing: FanousScale.spacingMd)], spacing: FanousScale.spacingMd
            ) {
                ForEach(items) { asset in tile(asset) }
            }
        }
    }

    private func tile(_ asset: StudioAsset) -> some View {
        let language = l10n.language
        return VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
            AssetThumbnail(model: model, asset: asset)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.name).fanousFont(.label).foregroundStyle(Fanous.textPrimary).lineLimit(1)
                    Text(
                        [
                            asset.bytes.formatted(ByteCountFormatStyle(style: .memory, locale: language.locale)),
                            asset.createdAt?.formatted(.dateTime.day().month().year().locale(language.locale)),
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                    .fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                }
                Spacer(minLength: FanousScale.spacingSm)
                if model.library.canEdit {
                    Button {
                        deleting = asset
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(FanousIconButtonStyle())
                    .disabled(model.busy)
                    .accessibilityLabel(l10n("studio.assets.deleteNamed", asset.name))
                    .accessibilityIdentifier("asset-delete-\(asset.id)")
                }
            }
        }
        .padding(FanousScale.spacingMd)
        .fanousMaterial(.card) { .rounded($0.md) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("asset-\(asset.id)")
    }
}

/// An image asset's picture, or the kind's symbol for videos and audio.
struct AssetThumbnail: View {
    let model: InstitutionModel
    let asset: StudioAsset
    @State private var image: Image?

    var body: some View {
        ZStack {
            Rectangle().fill(Fanous.surfaceRaised)
            if let image {
                image.resizable().scaledToFit().padding(FanousScale.spacingSm)
            } else {
                Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Fanous.textSecondary)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: asset.id) {
            guard asset.kind == .image,
                let data = try? await model.services.institution.assetData(id: asset.id, channelID: model.channelID)
            else { return }
            #if os(macOS)
                image = NSImage(data: data).map(Image.init(nsImage:))
            #else
                image = UIImage(data: data).map(Image.init(uiImage:))
            #endif
        }
    }

    private var symbol: String {
        switch asset.kind {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        }
    }
}

import AUNCoreBridge
import Foundation
import Observation

/// The account's brand kit and shared asset library (E19 19.9). Team members acting as a channel they help run read the
/// owner's kit and library; only the owner changes them (the server answers 403 to anyone else).
@MainActor @Observable
final class InstitutionModel {
    enum Load: Equatable { case loading, loaded, failed }

    let services: StudioServices
    let channelID: String
    private(set) var load: Load = .loading
    private(set) var saved = BrandKit()
    /// The kit as edited, before saving.
    var kit = BrandKit()
    private(set) var canEdit = false
    private(set) var library = StudioAssetLibrary(assets: [], canEdit: false)
    private(set) var busy = false
    private(set) var uploading: String?
    var message: StudioMessage?

    init(services: StudioServices, channelID: String) {
        self.services = services
        self.channelID = channelID
    }

    private var institution: any InstitutionServicing { services.institution }

    var hasChanges: Bool { kit != saved }

    /// Colours the server would refuse, so Save stays off until they are fixed.
    var invalidColors: [String] {
        let colors = kit.colors
        return [
            ("primary", colors.primary), ("secondary", colors.secondary), ("text", colors.text),
            ("background", colors.background),
        ]
        .filter { !BrandKit.isValidColor($0.1) }.map(\.0)
    }

    var canSave: Bool { canEdit && hasChanges && invalidColors.isEmpty && !busy }

    func refresh() async {
        do {
            async let state = institution.brandKit(channelID: channelID)
            async let assets = institution.assets(channelID: channelID)
            let loaded = try await state
            saved = loaded.kit
            kit = loaded.kit
            canEdit = loaded.canEdit
            library = try await assets
            load = .loaded
        } catch is CancellationError {
        } catch {
            AUNLog.studio.error("Brand kit failed: \(error)")
            if load != .loaded { load = .failed }
        }
    }

    /// Assets a kit slot may point at: an image for the logo, videos for the intro and outro.
    func assets(of kind: StudioAsset.Kind) -> [StudioAsset] { library.assets.filter { $0.kind == kind } }

    func asset(_ id: String?) -> StudioAsset? { id.flatMap { id in library.assets.first { $0.id == id } } }

    func save() async {
        guard canSave else { return }
        busy = true
        defer { busy = false }
        do {
            saved = try await institution.saveBrandKit(kit)
            kit = saved
            message = ("studio.brand.saved", [])
        } catch {
            AUNLog.studio.error("Saving the brand kit failed: \(error)")
            message = Self.message(for: error)
        }
    }

    func revert() { kit = saved }

    /// Checks the library's limits before sending any bytes, then uploads; the server reads the type from the bytes.
    func add(file url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if let refusal = library.refusal(forFileOfSize: size) {
            message = ("studio.assets.error.\(refusal)", [])
            return
        }
        uploading = url.lastPathComponent
        defer { uploading = nil }
        do {
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            let asset = try await institution.addAsset(name: url.deletingPathExtension().lastPathComponent, bytes: bytes)
            library.assets.insert(asset, at: 0)
            library.bytes += asset.bytes
            message = ("studio.assets.added", [])
        } catch {
            AUNLog.studio.error("Adding an asset failed: \(error)")
            message = Self.message(for: error)
        }
    }

    func delete(_ asset: StudioAsset) async {
        busy = true
        defer { busy = false }
        do {
            try await institution.deleteAsset(id: asset.id)
            library.assets.removeAll { $0.id == asset.id }
            library.bytes = max(0, library.bytes - asset.bytes)
            // The server clears kit slots that pointed at the asset; mirror it so the editor never shows a missing file.
            for slot in [\BrandKit.logo, \BrandKit.intro, \BrandKit.outro] {
                if saved[keyPath: slot] == asset.id { saved[keyPath: slot] = nil }
                if kit[keyPath: slot] == asset.id { kit[keyPath: slot] = nil }
            }
            message = ("studio.assets.deleted", [])
        } catch {
            AUNLog.studio.error("Deleting an asset failed: \(error)")
            message = Self.message(for: error)
        }
    }

    static func message(for error: any Error) -> StudioMessage {
        switch error as? CoreError {
        case .forbidden, .http(status: 403): ("studio.brand.ownerOnly", [])
        case .conflict("library_full", _): ("studio.assets.error.library_full", [])
        case .invalid("too_large"): ("studio.assets.error.too_large", [])
        case .invalid("empty"): ("studio.assets.error.empty", [])
        case .invalid("unsupported_type"): ("studio.assets.error.unsupported", [])
        case .invalid: ("studio.brand.invalid", [])
        default:
            StudioFailure.message(error)
        }
    }
}

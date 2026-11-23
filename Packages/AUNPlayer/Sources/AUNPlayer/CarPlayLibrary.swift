import AUNCoreBridge
import AUNDesign
import Foundation

/// Top-level shallow audio-only CarPlay tabs (E14-S9, Apple CarPlay Audio HIG).
/// Localized through `AUNDesign`'s `L10n` table using the in-app language setting.
public enum CarPlayTab: String, CaseIterable, Hashable, Sendable {
    case continueListening
    case downloads
    case subscriptions
    case recitation

    public var localizationKey: String {
        switch self {
        case .continueListening: "carplay.tab.continue"
        case .downloads: "carplay.tab.downloads"
        case .subscriptions: "carplay.tab.subscriptions"
        case .recitation: "carplay.tab.recitation"
        }
    }

    public func title(l10n: L10n) -> String {
        l10n(localizationKey)
    }
}

public struct CarPlayEntry: Identifiable, Hashable, Sendable {
    public var id: String { videoId }
    public var videoId: String
    public var title: String
    public var titleAr: String?
    public var channelName: String?
    public var thumbnailPath: String?
    public var audioURL: URL?
    public var durationSeconds: Double?
    public var isOffline: Bool

    public func localizedTitle(language: AppLanguage) -> String {
        if language == .ar, let titleAr, !titleAr.isEmpty { return titleAr }
        return title
    }

    public init(
        videoId: String,
        title: String,
        titleAr: String? = nil,
        channelName: String? = nil,
        thumbnailPath: String? = nil,
        audioURL: URL? = nil,
        durationSeconds: Double? = nil,
        isOffline: Bool = false
    ) {
        self.videoId = videoId
        self.title = title
        self.titleAr = titleAr
        self.channelName = channelName
        self.thumbnailPath = thumbnailPath
        self.audioURL = audioURL
        self.durationSeconds = durationSeconds
        self.isOffline = isOffline
    }
}

public struct CarPlayTabModel: Hashable, Sendable {
    public var tab: CarPlayTab
    public var title: String
    public var items: [CarPlayEntry]

    public init(tab: CarPlayTab, title: String, items: [CarPlayEntry]) {
        self.tab = tab
        self.title = title
        self.items = items
    }
}

public struct CarPlayLibraryInput: Hashable, Sendable {
    public var continueListening: [CarPlayEntry]
    public var downloads: [OfflineDownloadRecord]
    public var subscriptions: [CarPlayEntry]
    public var recitations: [CarPlayEntry]

    public init(
        continueListening: [CarPlayEntry] = [],
        downloads: [OfflineDownloadRecord] = [],
        subscriptions: [CarPlayEntry] = [],
        recitations: [CarPlayEntry] = []
    ) {
        self.continueListening = continueListening
        self.downloads = downloads
        self.subscriptions = subscriptions
        self.recitations = recitations
    }
}

/// Platform-neutral CarPlay library model & voice-search resolver (tested on macOS without CarPlay UI).
/// Completely hidden while `listenMode` is off (`GET /api/me/features`).
public struct CarPlayLibraryBuilder: Sendable {
    public init() {}

    public func buildTabs(
        input: CarPlayLibraryInput,
        features: UserFeatures,
        language: AppLanguage,
        maxItemsPerTab: Int = 50
    ) -> [CarPlayTabModel] {
        buildTabs(
            input: input,
            listenModeEnabled: features.isOn(.listenMode),
            offlineDownloadsEnabled: features.isOn(.offlineDownloads),
            language: language,
            maxItemsPerTab: maxItemsPerTab
        )
    }

    public func buildTabs(
        input: CarPlayLibraryInput,
        listenModeEnabled: Bool,
        offlineDownloadsEnabled: Bool,
        language: AppLanguage,
        maxItemsPerTab: Int = 50
    ) -> [CarPlayTabModel] {
        guard listenModeEnabled else { return [] }
        let l10n = L10n(language)
        let cap = max(0, maxItemsPerTab)
        var tabs: [CarPlayTabModel] = [
            CarPlayTabModel(
                tab: .continueListening,
                title: CarPlayTab.continueListening.title(l10n: l10n),
                items: Array(input.continueListening.prefix(cap))
            )
        ]
        if offlineDownloadsEnabled {
            let offlineEntries = input.downloads.prefix(cap).map { rec in
                CarPlayEntry(
                    videoId: rec.videoId,
                    title: rec.title,
                    titleAr: rec.titleAr,
                    channelName: rec.channelName,
                    thumbnailPath: rec.thumbnailPath,
                    durationSeconds: rec.durationSeconds,
                    isOffline: true
                )
            }
            tabs.append(
                CarPlayTabModel(
                    tab: .downloads,
                    title: CarPlayTab.downloads.title(l10n: l10n),
                    items: offlineEntries
                )
            )
        }
        tabs.append(
            CarPlayTabModel(
                tab: .subscriptions,
                title: CarPlayTab.subscriptions.title(l10n: l10n),
                items: Array(input.subscriptions.prefix(cap))
            )
        )
        tabs.append(
            CarPlayTabModel(
                tab: .recitation,
                title: CarPlayTab.recitation.title(l10n: l10n),
                items: Array(input.recitations.prefix(cap))
            )
        )
        return tabs
    }

    /// Resolves Siri / CarPlay voice queries across offline downloads first, then online items.
    public func search(
        query: String,
        downloads: [OfflineDownloadRecord],
        onlinePool: [CarPlayEntry],
        listenModeEnabled: Bool,
        offlineDownloadsEnabled: Bool
    ) -> [CarPlayEntry] {
        guard listenModeEnabled else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var seen = Set<String>()
        var results: [CarPlayEntry] = []

        if offlineDownloadsEnabled {
            for rec in downloads {
                let hay = [rec.title, rec.titleAr ?? "", rec.channelName ?? ""].joined(separator: " ").lowercased()
                if hay.contains(needle), seen.insert(rec.videoId).inserted {
                    results.append(
                        CarPlayEntry(
                            videoId: rec.videoId,
                            title: rec.title,
                            titleAr: rec.titleAr,
                            channelName: rec.channelName,
                            thumbnailPath: rec.thumbnailPath,
                            durationSeconds: rec.durationSeconds,
                            isOffline: true
                        )
                    )
                }
            }
        }
        for item in onlinePool {
            let hay = [item.title, item.titleAr ?? "", item.channelName ?? ""].joined(separator: " ").lowercased()
            if hay.contains(needle), seen.insert(item.videoId).inserted {
                results.append(item)
            }
        }
        return results
    }
}

#if canImport(CarPlay) && os(iOS)
    import CarPlay
    import UIKit

    /// Audio-only CarPlay template scene delegate (E14-S9).
    /// Gated on `listenMode` + `offlineDownloads` from `/api/me/features` and inactive in store
    /// builds until `com.apple.developer.carplay-audio` is provisioned (E14-D7).
    @MainActor
    public final class AUNCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
        private var interfaceController: CPInterfaceController?
        public var onSelectEntry: ((CarPlayEntry) -> Void)?
        public var features: UserFeatures = .none
        public var language: AppLanguage = .en

        public func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didConnect interfaceController: CPInterfaceController
        ) {
            self.interfaceController = interfaceController
            let tabs = CarPlayLibraryBuilder().buildTabs(
                input: CarPlayLibraryInput(),
                features: features,
                language: language,
                maxItemsPerTab: CPListTemplate.maximumItemCount
            )
            updateTemplates(tabs: tabs, language: language)
        }

        public func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didDisconnectInterfaceController interfaceController: CPInterfaceController
        ) {
            self.interfaceController = nil
        }

        public func updateTemplates(tabs: [CarPlayTabModel], language: AppLanguage) {
            guard let interfaceController else { return }
            self.language = language
            let maxItems = max(1, CPListTemplate.maximumItemCount)
            let maxSections = max(1, CPListTemplate.maximumSectionCount)
            let listTemplates: [CPListTemplate] = tabs.prefix(CPTabBarTemplate.maximumTabCount).map { model in
                let items = model.items.prefix(maxItems).map { entry -> CPListItem in
                    let image = entry.thumbnailPath.flatMap { UIImage(contentsOfFile: $0) }
                    let item = CPListItem(
                        text: entry.localizedTitle(language: language),
                        detailText: entry.channelName,
                        image: image
                    )
                    item.handler = { [weak self] _, completion in
                        self?.onSelectEntry?(entry)
                        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                        completion()
                    }
                    return item
                }
                let sections = Array([CPListSection(items: items)].prefix(maxSections))
                let template = CPListTemplate(title: model.title, sections: sections)
                template.tabTitle = model.title
                return template
            }
            if listTemplates.isEmpty {
                let empty = CPListTemplate(title: L10n(language)("carplay.tab.continue"), sections: [])
                interfaceController.setRootTemplate(empty, animated: false, completion: nil)
                return
            }
            interfaceController.setRootTemplate(CPTabBarTemplate(templates: listTemplates), animated: true, completion: nil)
        }
    }
#endif

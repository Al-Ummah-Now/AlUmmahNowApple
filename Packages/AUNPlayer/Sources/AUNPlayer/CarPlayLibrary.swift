import Foundation

/// Top-level shallow audio-only CarPlay tabs (E14-S9, Apple CarPlay Audio HIG).
public enum CarPlayTab: String, CaseIterable, Hashable, Sendable {
    case continueListening
    case downloads
    case subscriptions
    case recitation

    public func title(isArabic: Bool) -> String {
        switch (self, isArabic) {
        case (.continueListening, false): "Continue listening"
        case (.continueListening, true): "متابعة الاستماع"
        case (.downloads, false): "Downloads"
        case (.downloads, true): "التنزيلات"
        case (.subscriptions, false): "Subscriptions"
        case (.subscriptions, true): "الاشتراكات"
        case (.recitation, false): "Recitation"
        case (.recitation, true): "التلاوة"
        }
    }
}

public struct CarPlayEntry: Identifiable, Hashable, Sendable {
    public var id: String { videoId }
    public var videoId: String
    public var title: String
    public var titleAr: String?
    public var channelName: String?
    public var durationSeconds: Double?
    public var isOffline: Bool

    public func localizedTitle(isArabic: Bool) -> String {
        if isArabic, let titleAr, !titleAr.isEmpty { return titleAr }
        return title
    }

    public init(
        videoId: String,
        title: String,
        titleAr: String? = nil,
        channelName: String? = nil,
        durationSeconds: Double? = nil,
        isOffline: Bool = false
    ) {
        self.videoId = videoId
        self.title = title
        self.titleAr = titleAr
        self.channelName = channelName
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
public struct CarPlayLibraryBuilder: Sendable {
    public init() {}

    public func buildTabs(
        input: CarPlayLibraryInput,
        offlineDownloadsEnabled: Bool,
        isArabic: Bool
    ) -> [CarPlayTabModel] {
        var tabs: [CarPlayTabModel] = [
            CarPlayTabModel(tab: .continueListening, title: CarPlayTab.continueListening.title(isArabic: isArabic), items: input.continueListening),
        ]
        if offlineDownloadsEnabled {
            let offlineEntries = input.downloads.map { rec in
                CarPlayEntry(
                    videoId: rec.videoId,
                    title: rec.title,
                    titleAr: rec.titleAr,
                    channelName: rec.channelName,
                    durationSeconds: rec.durationSeconds,
                    isOffline: true
                )
            }
            tabs.append(CarPlayTabModel(tab: .downloads, title: CarPlayTab.downloads.title(isArabic: isArabic), items: offlineEntries))
        }
        tabs.append(CarPlayTabModel(tab: .subscriptions, title: CarPlayTab.subscriptions.title(isArabic: isArabic), items: input.subscriptions))
        tabs.append(CarPlayTabModel(tab: .recitation, title: CarPlayTab.recitation.title(isArabic: isArabic), items: input.recitations))
        return tabs
    }

    /// Resolves Siri / CarPlay voice queries across offline downloads first, then online items.
    public func search(
        query: String,
        downloads: [OfflineDownloadRecord],
        onlinePool: [CarPlayEntry],
        offlineDownloadsEnabled: Bool
    ) -> [CarPlayEntry] {
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

    /// Audio-only CarPlay template scene delegate (E14-S9).
    /// Activated once the owner adds the `com.apple.developer.carplay-audio` entitlement (E14-D7).
    @MainActor
    public final class AUNCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
        private var interfaceController: CPInterfaceController?
        public var onSelectEntry: ((CarPlayEntry) -> Void)?

        public func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didConnect interfaceController: CPInterfaceController
        ) {
            self.interfaceController = interfaceController
            let isArabic = Locale.current.language.languageCode?.identifier == "ar"
            let emptyTabs = CarPlayLibraryBuilder().buildTabs(
                input: CarPlayLibraryInput(),
                offlineDownloadsEnabled: false,
                isArabic: isArabic
            )
            updateTemplates(tabs: emptyTabs, isArabic: isArabic)
        }

        public func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didDisconnectInterfaceController interfaceController: CPInterfaceController
        ) {
            self.interfaceController = nil
        }

        public func updateTemplates(tabs: [CarPlayTabModel], isArabic: Bool) {
            guard let interfaceController else { return }
            let listTemplates: [CPListTemplate] = tabs.map { model in
                let items = model.items.map { entry -> CPListItem in
                    let item = CPListItem(text: entry.localizedTitle(isArabic: isArabic), detailText: entry.channelName)
                    item.handler = { [weak self] _, completion in
                        self?.onSelectEntry?(entry)
                        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                        completion()
                    }
                    return item
                }
                let section = CPListSection(items: items)
                let template = CPListTemplate(title: model.title, sections: [section])
                template.tabTitle = model.title
                return template
            }
            interfaceController.setRootTemplate(CPTabBarTemplate(templates: listTemplates), animated: true, completion: nil)
        }
    }
#endif

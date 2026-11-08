#if os(iOS)
    import AUNCoreBridge
    import AUNDesign
    import SnapshotTesting
    import SwiftUI
    import Testing
    import UIKit

    @testable import AUNFeatures

    /// Reference images are recorded on the iOS 26.4 simulator with `RECORD_SNAPSHOTS=1`.
    @MainActor @Suite(.serialized) struct SnapshotTests {
        private func assertView(
            _ view: some View, name: String, language: AppLanguage, style: UIUserInterfaceStyle, line: UInt = #line
        ) {
            let root =
                view
                .environment(\.l10n, L10n(language))
                .environment(\.locale, language.locale)
                .environment(\.layoutDirection, language.isRTL ? .rightToLeft : .leftToRight)
            let host = UIHostingController(rootView: root)
            let traits = UITraitCollection(userInterfaceStyle: style)
            let record = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
            withSnapshotTesting(record: record ? .all : .never) {
                assertSnapshot(
                    of: host,
                    as: .image(precision: 0.97, perceptualPrecision: 0.95, size: CGSize(width: 393, height: 620), traits: traits),
                    named: "\(name)-\(language.rawValue)-\(style == .dark ? "dark" : "light")",
                    line: line)
            }
        }

        private var rails: [HomeRail] {
            [
                HomeRail(kind: .trending, videos: Array(FixtureCatalogService.videos.prefix(3))),
                HomeRail(kind: .recent, videos: Array(FixtureCatalogService.videos.suffix(3))),
            ]
        }

        private var content: WatchContent {
            WatchContent(
                video: FixtureCatalogService.videos[0],
                chapters: [
                    Chapter(
                        id: "1", startTime: 0, title: "Introduction",
                        titleLocalized: LocalizedText(en: "Introduction", ar: "المقدمة")),
                    Chapter(
                        id: "2", startTime: 90, title: "Sources", titleLocalized: LocalizedText(en: "Sources", ar: "المصادر")),
                ])
        }

        @Test(arguments: [AppLanguage.en, .ar], [UIUserInterfaceStyle.dark, .light])
        func home(language: AppLanguage, style: UIUserInterfaceStyle) {
            assertView(HomeRailsContent(rails: rails, open: { _ in }), name: "home", language: language, style: style)
        }

        @Test(arguments: [AppLanguage.en, .ar], [UIUserInterfaceStyle.dark, .light])
        func watchDetails(language: AppLanguage, style: UIUserInterfaceStyle) {
            assertView(
                WatchDetails(content: content, seek: { _ in }).padding().frame(maxHeight: .infinity, alignment: .top).background(
                    Fanous.background),
                name: "watch", language: language, style: style)
        }
    }
#endif

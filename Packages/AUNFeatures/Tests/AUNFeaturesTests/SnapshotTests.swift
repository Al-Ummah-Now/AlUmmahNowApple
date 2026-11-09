#if os(iOS)
    import AUNCoreBridge
    import AUNDesign
    import SnapshotTesting
    import SwiftUI
    import Testing
    import UIKit

    @testable import AUNFeatures

    /// Every key screen in every site theme, light and dark, English and Arabic.
    ///
    /// References come from the CI simulator (iOS 26.4): a missing reference is recorded and fails the run, and CI
    /// uploads `__Snapshots__` as an artifact to commit. `RECORD_SNAPSHOTS=1` re-records them all.
    @MainActor @Suite(.serialized) struct SnapshotTests {
        static let themes = FanousThemeID.allCases
        static let languages = [AppLanguage.en, .ar]
        static let styles = [UIUserInterfaceStyle.light, .dark]

        private func assertView(
            _ view: some View, name: String, theme: FanousThemeID, language: AppLanguage, style: UIUserInterfaceStyle,
            line: UInt = #line
        ) {
            let root =
                view
                .fanousTheme(theme, dark: style == .dark)
                .environment(\.l10n, L10n(language))
                .environment(\.locale, language.locale)
                .environment(\.layoutDirection, language.isRTL ? .rightToLeft : .leftToRight)
            let host = UIHostingController(rootView: root)
            let traits = UITraitCollection(userInterfaceStyle: style)
            let record = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
            withSnapshotTesting(record: record ? .all : .missing) {
                assertSnapshot(
                    of: host,
                    as: .image(precision: 0.97, perceptualPrecision: 0.95, size: CGSize(width: 393, height: 620), traits: traits),
                    named: "\(name)-\(theme.rawValue)-\(language.rawValue)-\(style == .dark ? "dark" : "light")",
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

        @Test(arguments: themes, languages)
        func home(theme: FanousThemeID, language: AppLanguage) {
            for style in Self.styles {
                assertView(
                    HomeRailsContent(rails: rails, open: { _ in }), name: "home", theme: theme, language: language, style: style)
            }
        }

        @Test(arguments: themes, languages)
        func watchDetails(theme: FanousThemeID, language: AppLanguage) {
            for style in Self.styles {
                assertView(
                    WatchDetails(content: content, seek: { _ in }).padding().frame(maxHeight: .infinity, alignment: .top)
                        .fanousMaterial(.page),
                    name: "watch", theme: theme, language: language, style: style)
            }
        }
    }
#endif

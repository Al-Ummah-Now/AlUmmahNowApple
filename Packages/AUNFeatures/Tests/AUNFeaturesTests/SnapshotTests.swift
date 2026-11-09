#if os(iOS)
    import AUNCoreBridge
    import AUNDesign
    import AUNPlayer
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
        nonisolated static let themes = FanousThemeID.allCases
        nonisolated static let languages = [AppLanguage.en, .ar]
        nonisolated static let styles = [UIUserInterfaceStyle.light, .dark]

        private func assertView(
            _ view: some View, name: String, theme: FanousThemeID, language: AppLanguage, style: UIUserInterfaceStyle,
            line: UInt = #line
        ) {
            let root =
                view
                .fanousTheme(theme, dark: style == .dark)
                // Loops (loader breath, skeleton shine) land on their end state, so every render is the same.
                .transaction { $0.disablesAnimations = true }
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

        private func player(menu: PlayerMenu?) -> some View {
            let video = FixtureCatalogService.videos[0]
            let item = PlaybackItem(
                url: URL(string: "https://cdn.test/v.m3u8")!, title: video.title, subtitle: nil,
                resolutions: ["240p", "480p", "720p"], subtitles: [], chapters: content.chapters)
            let controller = PlayerController.preview(item: item, currentTime: 3, duration: 26, buffered: 14, playing: false)
            return PlayerSnapshotFrame(controller: controller, menu: menu).padding(12).frame(
                maxHeight: .infinity, alignment: .top
            )
            .fanousPage()
        }

        @Test(arguments: themes, languages)
        func playerControls(theme: FanousThemeID, language: AppLanguage) {
            for style in Self.styles {
                assertView(player(menu: nil), name: "player", theme: theme, language: language, style: style)
            }
            assertView(player(menu: .settings), name: "player-menu", theme: theme, language: language, style: .dark)
        }

        @Test(arguments: themes, languages)
        func states(theme: FanousThemeID, language: AppLanguage) {
            for style in Self.styles {
                assertView(
                    VStack(spacing: 0) {
                        HomeSkeleton().frame(height: 300).clipped()
                        ErrorStateView {}
                    }
                    .fanousPage(),
                    name: "states", theme: theme, language: language, style: style)
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

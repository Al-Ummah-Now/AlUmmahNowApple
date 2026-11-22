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
    /// References come from the CI simulator (iPhone 17, iOS 27.0): a missing reference is recorded and fails the run, and CI
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

        /// Title cards in the snapshot's language, as the app shows them.
        private func rails(_ language: AppLanguage) -> [HomeRail] {
            let videos = FixtureCatalogService.videos(arabic: language == .ar)
            return [
                HomeRail(kind: .trending, videos: Array(videos.prefix(3))),
                HomeRail(kind: .recent, videos: Array(videos.suffix(3))),
            ]
        }

        /// The first video with its own chapters, as the watch page loads them.
        private func content(_ language: AppLanguage) -> WatchContent {
            let video = FixtureCatalogService.videos(arabic: language == .ar)[0]
            return WatchContent(video: video, chapters: FixtureLibrary.chapters(viewerID: video.id))
        }

        @Test(arguments: themes, languages)
        func home(theme: FanousThemeID, language: AppLanguage) {
            for style in Self.styles {
                assertView(
                    HomeRailsContent(rails: rails(language), open: { _ in }), name: "home", theme: theme, language: language,
                    style: style)
            }
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
                    WatchDetails(content: content(language), seek: { _ in }).padding().frame(
                        maxHeight: .infinity, alignment: .top
                    )
                    .fanousMaterial(.page),
                    name: "watch", theme: theme, language: language, style: style)
            }
        }
    }
#endif

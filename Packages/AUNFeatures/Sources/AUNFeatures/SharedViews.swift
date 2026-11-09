import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Card content shared by phone, tablet, desktop and TV: the web's `.video-card`, a lifted thumbnail over plain text.
struct VideoCardContent: View {
    @Environment(\.l10n) private var l10n
    let video: Video
    var lifted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailImage(url: video.thumbnailURL, lifted: lifted)
                .overlay(alignment: .bottomTrailing) {
                    if let duration = video.durationSeconds {
                        DurationBadge(DisplayFormat.duration(duration, l10n.language)).padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(video.displayTitle(l10n.language))
                    .fanousFont(.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(Fanous.part(\.cardVideoTitle))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(metadata)
                    .fanousFont(.caption)
                    .foregroundStyle(Fanous.part(\.cardVideoMeta))
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: String {
        let views = l10n("video.views", DisplayFormat.count(video.views, l10n.language))
        return [video.channelName, views].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A card that lifts and shows the thumbnail edge while pressed, as the web does on hover and focus.
struct VideoCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? -2 : 0)
            .animation(.easeOut(duration: FanousScale.durationStandard), value: configuration.isPressed)
    }
}

struct RailHeader: View {
    @Environment(\.l10n) private var l10n
    let kind: HomeRailKind

    var body: some View {
        Text(l10n(kind.titleKey))
            .fanousFont(.title)
            .fontWeight(.bold)
            .foregroundStyle(Fanous.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Language and light or dark choice, available wherever the app has a top bar. The site theme is set by an admin.
struct SettingsMenu: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.l10n) private var l10n

    var body: some View {
        Menu {
            Picker(l10n("common.language"), selection: Binding(get: { settings.language }, set: { settings.language = $0 })) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(l10n("language.\(language.rawValue)")).tag(language)
                }
            }
            Picker(l10n("common.theme"), selection: Binding(get: { settings.theme }, set: { settings.theme = $0 })) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(l10n("theme.\(theme.rawValue)")).tag(theme)
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Fanous.part(\.navIcon))
                .accessibilityLabel(l10n("common.settings"))
        }
        .accessibilityIdentifier("settings-menu")
    }
}

extension View {
    /// The app header in the theme's nav colours (`--m-header` sits under the bar's own material).
    func fanousNavigationBar() -> some View {
        #if os(iOS)
            self.toolbarBackground(Fanous.part(\.navBg), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        #elseif os(macOS)
            self.toolbarBackground(Fanous.part(\.navBg), for: .windowToolbar)
        #else
            self
        #endif
    }
}

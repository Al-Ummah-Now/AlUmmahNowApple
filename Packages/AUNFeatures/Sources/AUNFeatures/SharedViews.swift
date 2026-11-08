import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Card content shared by phone, tablet, desktop and TV.
struct VideoCardContent: View {
    @Environment(\.l10n) private var l10n
    let video: Video

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailImage(url: video.thumbnailURL)
                .overlay(alignment: .bottomTrailing) {
                    if let duration = video.durationSeconds {
                        Text(DisplayFormat.duration(duration, l10n.language))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Fanous.textPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Fanous.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(video.displayTitle(l10n.language))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Fanous.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(metadata)
                .font(.caption)
                .foregroundStyle(Fanous.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: String {
        let views = l10n("video.views", DisplayFormat.count(video.views, l10n.language))
        return [video.channelName, views].compactMap { $0 }.joined(separator: " · ")
    }
}

struct RailHeader: View {
    @Environment(\.l10n) private var l10n
    let kind: HomeRailKind

    var body: some View {
        Text(l10n(kind.titleKey))
            .font(.title3.weight(.bold))
            .foregroundStyle(Fanous.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Language and theme choice, available wherever the app has a top bar.
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
            Image(systemName: "gearshape").accessibilityLabel(l10n("common.settings"))
        }
        .accessibilityIdentifier("settings-menu")
    }
}

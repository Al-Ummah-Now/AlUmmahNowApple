import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Card content shared by phone, tablet, desktop and TV: the web's `.video-card`, a lifted thumbnail over plain text.
struct VideoCardContent: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                metadata
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: some View {
        let views = DisplayFormat.views(video.views, l10n)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    if let channel = video.channelName, !channel.isEmpty {
                        Text(DisplayFormat.meta([channel], l10n.language))
                    }
                    Text(DisplayFormat.meta([views], l10n.language))
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(DisplayFormat.meta([video.channelName, views], l10n.language)).lineLimit(1)
            }
        }
        .fanousFont(.caption)
        .foregroundStyle(Fanous.part(\.cardVideoMeta))
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
    let environment: AppEnvironment
    var telemetry: any TelemetryServicing = NullTelemetryService.shared
    var onOpenBlockedList: (() -> Void)?
    @State private var showingPurgeWarning = false

    private var diagnosticsBinding: Binding<Bool> {
        Binding(
            get: { settings.telemetryEnabled && telemetry.consent != .off },
            set: { enabled in
                if enabled {
                    settings.telemetryEnabled = true
                    if !telemetry.setConsent(.full) {
                        settings.telemetryEnabled = false
                    }
                } else {
                    if settings.telemetryEnabled { settings.telemetryEnabled = false }
                    if !telemetry.setConsent(.off) { showingPurgeWarning = true }
                }
            }
        )
    }

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
            Divider()
            Toggle(isOn: diagnosticsBinding) {
                Label(l10n("diagnostics.toggle"), systemImage: "waveform.path.ecg")
            }
            .accessibilityIdentifier("settings-diagnostics")
            if telemetry.consent == .off && telemetry.lastPurgeFailed {
                Button(l10n("common.retry")) {
                    if !telemetry.setConsent(.off) { showingPurgeWarning = true }
                }
                .accessibilityIdentifier("settings-diagnostics-retry-purge")
            }
            #if os(iOS) || os(macOS)
                if let onOpenBlockedList {
                    Divider()
                    Button {
                        onOpenBlockedList()
                    } label: {
                        Label(l10n("safety.blockedList.title"), systemImage: "hand.raised.slash")
                    }
                    .accessibilityIdentifier("settings-blocked-list")
                }
            #endif
            Divider()
            Link(destination: AUNSupportLinks.help(language: l10n.language.rawValue, environment: environment)) {
                Label(l10n("common.help"), systemImage: "questionmark.circle")
            }
            .accessibilityIdentifier("settings-help")
            Link(destination: AUNSupportLinks.contact(language: l10n.language.rawValue, environment: environment)) {
                Label(l10n("common.contact"), systemImage: "envelope")
            }
            .accessibilityIdentifier("settings-contact")
            Link(destination: AUNSupportLinks.privacy(language: l10n.language.rawValue, environment: environment)) {
                Label(l10n("common.privacyPolicy"), systemImage: "hand.raised")
            }
            .accessibilityIdentifier("settings-privacy")
            Link(destination: AUNSupportLinks.terms(language: l10n.language.rawValue, environment: environment)) {
                Label(l10n("common.termsOfService"), systemImage: "doc.text")
            }
            .accessibilityIdentifier("settings-terms")
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .medium))
                // The Mac's toolbar is the page's colour, not the navy header
                #if os(macOS)
                    .foregroundStyle(Fanous.textPrimary)
                #else
                    .foregroundStyle(Fanous.part(\.navIcon))
                #endif
                .accessibilityLabel(l10n("common.settings"))
        }
        .accessibilityIdentifier("settings-menu")
        .alert(l10n("diagnostics.toggle"), isPresented: $showingPurgeWarning) {
            Button(l10n("common.retry")) {
                if !telemetry.setConsent(.off) { showingPurgeWarning = true }
            }
            Button(l10n("common.dismiss"), role: .cancel) {}
        } message: {
            Text(l10n("diagnostics.purgeWarning"))
        }
    }
}

extension View {
    /// The app header: the web header's colours (`FanousHeader`).
    func fanousNavigationBar() -> some View {
        #if os(tvOS)
            self
        #else
            fanousHeaderBar()
        #endif
    }
}

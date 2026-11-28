import AUNCoreBridge
import AUNDesign
import SwiftUI

/// The opt-in switch for crash reports and diagnostics, with the note under it.
struct StudioDiagnosticsSection: View {
    @Environment(\.l10n) private var l10n
    @Environment(AppSettings.self) private var settings
    let telemetry: any TelemetryServicing
    @State private var message: String?

    private var binding: Binding<Bool> {
        Binding(
            get: { settings.telemetryEnabled },
            set: { enabled in
                if enabled {
                    let applied = telemetry.setConsent(.full)
                    settings.telemetryEnabled = applied
                    message = applied ? nil : l10n("diagnostics.enableError")
                } else {
                    let purged = telemetry.setConsent(.off)
                    settings.telemetryEnabled = false
                    message = purged ? nil : l10n("diagnostics.purgeWarning")
                }
            }
        )
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                Toggle(l10n("diagnostics.toggle"), isOn: binding)
                    .accessibilityIdentifier("accounts-diagnostics")
                Text(l10n("diagnostics.description"))
                    .fanousFont(.caption)
                    .foregroundStyle(Fanous.textSecondary)
                if let message {
                    Text(message)
                        .fanousFont(.caption)
                        .foregroundStyle(Fanous.errorText)
                        .accessibilityIdentifier("accounts-diagnostics-warning")
                }
            }
            .padding(.vertical, 2)
        }
    }
}

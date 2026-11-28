import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Signed-in accounts: switch, add, diagnostics consent, and sign out (each with an in-app confirmation).
struct AccountsView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    let session: StudioSession
    @State private var leaving: StudioAccount?
    @State private var deleting: StudioAccount?
    @State private var diagnosticsMessage: String?
    @State private var showingEnableError = false

    private var diagnosticsBinding: Binding<Bool> {
        Binding(
            get: { settings.telemetryEnabled && session.services.telemetry.consent != .off },
            set: { enabled in
                let telemetry = session.services.telemetry
                if enabled {
                    settings.telemetryEnabled = true
                    if telemetry.setConsent(.full) {
                        diagnosticsMessage = nil
                    } else {
                        settings.telemetryEnabled = false
                        diagnosticsMessage = l10n("diagnostics.enableError")
                        showingEnableError = true
                    }
                } else {
                    if settings.telemetryEnabled { settings.telemetryEnabled = false }
                    let purged = telemetry.setConsent(.off)
                    diagnosticsMessage = purged ? nil : l10n("diagnostics.purgeWarning")
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.accounts) { account in row(account) }
                }
                .studioRows()
                Section {
                    Button {
                        Task {
                            await session.signIn(addingAccount: true)
                            if session.notice == nil { dismiss() }
                        }
                    } label: {
                        Label(l10n("studio.account.add"), systemImage: "person.badge.plus")
                    }
                    .disabled(session.isSigningIn || session.isDeletingAccount)
                    .accessibilityIdentifier("account-add")
                }
                .studioRows()
                Section {
                    VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                        Toggle(l10n("diagnostics.toggle"), isOn: diagnosticsBinding)
                            .accessibilityIdentifier("accounts-diagnostics")
                        Text(l10n("diagnostics.description"))
                            .fanousFont(.caption)
                            .foregroundStyle(Fanous.textSecondary)
                        if let message = diagnosticsMessage
                            ?? (session.services.telemetry.lastPurgeFailed ? l10n("diagnostics.purgeWarning") : nil)
                        {
                            Text(message)
                                .fanousFont(.caption)
                                .foregroundStyle(Fanous.errorText)
                                .accessibilityIdentifier("accounts-diagnostics-warning")
                        }
                        if session.services.telemetry.consent == .off && session.services.telemetry.lastPurgeFailed {
                            Button(l10n("common.retry")) {
                                let purged = session.services.telemetry.setConsent(.off)
                                diagnosticsMessage = purged ? nil : l10n("diagnostics.purgeWarning")
                            }
                            .accessibilityIdentifier("accounts-diagnostics-retry-purge")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .studioRows()
                Section {
                    StudioSupportLinksSection(environment: session.environment, idPrefix: "accounts")
                }
                .foregroundStyle(Fanous.accent)
                .studioRows()
                if let active = session.account {
                    Section {
                        Button(role: .destructive) {
                            deleting = active
                        } label: {
                            Label(l10n("studio.deleteAccount.button"), systemImage: "trash")
                                .foregroundStyle(Fanous.errorText)
                        }
                        .disabled(session.isSigningIn || session.isDeletingAccount)
                        .accessibilityIdentifier("account-delete")
                    }
                    .studioRows()
                }
                if session.notice != nil {
                    Section { NoticeView(session: session) }
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .fanousPage()
            .navigationTitle(l10n("studio.account.title"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                    ToolbarItem(placement: .principal) {
                        Text(l10n("studio.account.title")).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                    }
                #endif
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n("common.dismiss")) { dismiss() }.accessibilityIdentifier("accounts-done")
                }
            }
        }
        .environment(\.layoutDirection, l10n.language.isRTL ? .rightToLeft : .leftToRight)
        .sheet(item: $leaving) { account in
            ConfirmSheet(
                title: l10n("studio.signOut.title", account.label), message: l10n("studio.signOut.message"),
                actionTitle: l10n("studio.account.signOut")
            ) {
                Task {
                    await session.signOut(account.id)
                    if session.phase == .signedOut { dismiss() }
                }
            }
        }
        .sheet(item: $deleting) { account in
            DeleteAccountSheet(account: account, session: session) {
                if session.phase == .signedOut { dismiss() }
            }
        }
        .alert(l10n("diagnostics.toggle"), isPresented: $showingEnableError) {
            Button(l10n("common.dismiss"), role: .cancel) {}
        } message: {
            Text(l10n("diagnostics.enableError"))
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func row(_ account: StudioAccount) -> some View {
        let isActive = account.id == session.account?.id
        return HStack(spacing: FanousScale.spacingMd) {
            Button {
                Task {
                    if account.needsReauth {
                        await session.signIn(addingAccount: true)
                    } else {
                        await session.switchAccount(to: account.id)
                    }
                }
            } label: {
                HStack(spacing: FanousScale.spacingMd) {
                    AvatarView(name: account.label, url: account.avatarURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                        if let email = account.email, email != account.label {
                            OneLineAddress(email).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                        }
                        if session.openDeletion(of: account.id) != nil {
                            Text(l10n("studio.deleteAccount.openAccount")).fanousFont(.caption)
                                .foregroundStyle(Fanous.errorText)
                        }
                        if account.needsReauth {
                            Text(l10n("studio.account.reauth")).fanousFont(.caption).foregroundStyle(Fanous.errorText)
                        }
                    }
                    Spacer(minLength: 0)
                    if isActive {
                        Image(systemName: "checkmark").foregroundStyle(Fanous.accent)
                            .accessibilityLabel(l10n("studio.account.active"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.isDeletingAccount)
            .accessibilityHint(isActive ? "" : l10n("studio.account.switch", account.label))
            .accessibilityIdentifier("account-\(account.id)")
            Button(l10n("studio.account.signOut")) { leaving = account }
                .buttonStyle(.borderless)
                .disabled(session.isDeletingAccount)
                .foregroundStyle(Fanous.errorText)
                .accessibilityIdentifier("account-sign-out-\(account.id)")
        }
    }
}

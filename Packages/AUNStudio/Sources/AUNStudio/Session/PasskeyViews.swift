import AUNCoreBridge
import AUNDesign
import SwiftUI

/// "Sign in with a passkey" (the platform sheet, no browser) above "Sign in another way" (the auth site in the
/// browser sheet, unchanged). Shared by Studio and Admin.
public struct PasskeySignInButtons: View {
    @Environment(\.l10n) private var l10n
    let onPasskey: () -> Void
    let onAnotherWay: () -> Void

    public init(onPasskey: @escaping () -> Void, onAnotherWay: @escaping () -> Void) {
        self.onPasskey = onPasskey
        self.onAnotherWay = onAnotherWay
    }

    public var body: some View {
        VStack(spacing: FanousScale.spacingMd) {
            Button(action: onPasskey) {
                Label(l10n("passkey.signIn"), systemImage: "person.badge.key")
                    .frame(maxWidth: 320)
            }
            .buttonStyle(FanousButtonStyle(.primary))
            .accessibilityIdentifier("sign-in-passkey")
            // Read by VoiceOver right after the button, once (not repeated as the button's hint).
            Text(l10n("passkey.about")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onAnotherWay) {
                Text(l10n("passkey.signInAnotherWay")).frame(maxWidth: 320)
            }
            .buttonStyle(FanousButtonStyle(.ghost))
            .accessibilityIdentifier("sign-in")
        }
    }
}

/// A passkey message in the app (never a system alert), with its one follow-up and a dismiss button.
public struct PasskeyDialogSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var titleSpoken: Bool

    let dialog: PasskeyDialog
    let onAction: (PasskeyDialog.Action) -> Void

    public init(dialog: PasskeyDialog, onAction: @escaping (PasskeyDialog.Action) -> Void) {
        self.dialog = dialog
        self.onAction = onAction
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: FanousScale.spacingLg) {
                Image(systemName: dialog.isError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.title)
                    .foregroundStyle(dialog.isError ? Fanous.errorText : Fanous.accent)
                    .accessibilityHidden(true)
                Text(l10n(dialog.titleKey)).fanousFont(.title).foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleSpoken)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("passkey-dialog-message")
                VStack(spacing: FanousScale.spacingMd) {
                    if let action = dialog.action {
                        Button {
                            dismiss()
                            onAction(action)
                        } label: {
                            Text(l10n(actionKey(action))).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(FanousButtonStyle(.primary))
                        .accessibilityIdentifier("passkey-dialog-action")
                    }
                    Button {
                        dismiss()
                    } label: {
                        Text(l10n(dialog.action == nil ? "common.done" : "common.cancel")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FanousButtonStyle(dialog.action == nil ? .primary : .secondary))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("passkey-dialog-dismiss")
                }
                .frame(maxWidth: 320)
            }
            .multilineTextAlignment(.center)
            .padding(FanousScale.spacingXl)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { titleSpoken = true }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fanousPage()
        .accessibilityIdentifier("passkey-dialog")
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationBackground { FanousSurfaceKind(kind: .page, shape: .rect) }
        #else
            .frame(minWidth: 380, minHeight: 260)
        #endif
    }

    private var message: String {
        dialog.values.isEmpty ? l10n(dialog.messageKey) : l10n(dialog.messageKey, dialog.values[0])
    }

    private func actionKey(_ action: PasskeyDialog.Action) -> String {
        switch action {
        case .signInAnotherWay: "passkey.signInAnotherWay"
        case .signInAgain: "passkey.signInAgain"
        }
    }
}

/// "Add a passkey" in an account screen. Shared by Studio and Admin.
public struct AddPasskeyRow: View {
    @Environment(\.l10n) private var l10n
    let isBusy: Bool
    let action: () -> Void

    public init(isBusy: Bool, action: @escaping () -> Void) {
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: FanousScale.spacingMd) {
                Label {
                    VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                        Text(l10n("passkey.add")).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                        Text(l10n(isBusy ? "passkey.progress" : "passkey.about")).fanousFont(.caption)
                            .foregroundStyle(Fanous.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "person.badge.key").foregroundStyle(Fanous.accent)
                }
                Spacer(minLength: 0)
                if isBusy { ProgressView().accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-add-passkey")
    }
}

/// Where Studio shows `passkeyDialog`: over the accounts sheet while it is open, otherwise over the window (one sheet
/// cannot be presented from under another).
enum PasskeyDialogHost { case root, accounts }

extension View {
    func passkeyDialog(session: StudioSession, host: PasskeyDialogHost = .root) -> some View {
        modifier(StudioPasskeyDialog(session: session, host: host))
    }
}

private struct StudioPasskeyDialog: ViewModifier {
    @Bindable var session: StudioSession
    let host: PasskeyDialogHost

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(
                get: { (session.accountsOpen == (host == .accounts)) ? session.passkeyDialog : nil },
                set: { session.passkeyDialog = $0 })
        ) { dialog in
            PasskeyDialogSheet(dialog: dialog) { action in Task { await session.perform(action) } }
        }
    }
}

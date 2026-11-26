import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Says, on every screen, that a deletion of this account started and isn't finished. It can't be dismissed.
struct DeletionBanner: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession
    @State private var deleting: StudioAccount?

    var body: some View {
        // A container that is always there: the sheet stays while the banner itself is hidden.
        VStack(spacing: 0) {
            if let account = session.account, let record = session.openDeletion(of: account.id), !session.isDeletingAccount {
                VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                    Label {
                        Text(l10n(Self.text(record))).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Fanous.errorText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("deletion-banner")
                    let asks = record.stage == .deleteSent && !record.unsettled
                    Button(l10n(asks ? "studio.deleteAccount.check" : "studio.deleteAccount.finish")) {
                        if asks {
                            Task { await session.checkDeletions(asked: true) }
                        } else {
                            deleting = account
                        }
                    }
                    .buttonStyle(FanousButtonStyle(.secondary))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .disabled(session.isSigningIn || session.isCheckingDeletions)
                    .accessibilityIdentifier("deletion-finish")
                }
                .padding(FanousScale.spacingMd)
                .fanousMaterial(.raised) { .rounded($0.md) }
                .padding(.horizontal, FanousScale.spacingLg)
                .padding(.vertical, FanousScale.spacingSm)
            }
            if session.notice?.isAboutDeletion == true {
                NoticeView(session: session)
                    .padding(.horizontal, FanousScale.spacingLg)
                    .padding(.vertical, FanousScale.spacingSm)
            }
        }
        .sheet(item: $deleting) { account in DeleteAccountSheet(account: account, session: session) {} }
    }

    static func text(_ record: DeletionRecord) -> String {
        switch record.stage {
        case .deleteSent where record.unsettled: "studio.deleteAccount.openUnsettled"
        case .deleteSent: "studio.deleteAccount.openUnknown"
        case .contentErased where record.leftover.isEmpty: "studio.deleteAccount.openContentErased"
        case .contentErased where record.leftover == [.channel]: "studio.deleteAccount.openChannel"
        default: "studio.deleteAccount.open"
        }
    }
}

/// On the sign-in screen: the deletions that started here, of accounts that are not signed in.
struct SignedOutDeletions: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession

    var body: some View {
        ForEach(session.signedOutDeletions, id: \.accountID) { record in
            VStack(spacing: FanousScale.spacingSm) {
                Text(l10n(Self.text(record), DisplayFormat.isolate(record.label)))
                    .fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("deletion-signed-out")
                if record.unsettled {
                    Button(l10n("common.dismiss")) { session.dismissDeletion(of: record.accountID) }
                        .buttonStyle(FanousButtonStyle(.secondary))
                        .accessibilityIdentifier("deletion-dismiss")
                } else if record.stage == .deleteSent {
                    Button(l10n("studio.deleteAccount.check")) { Task { await session.checkDeletions(asked: true) } }
                        .buttonStyle(FanousButtonStyle(.secondary))
                        .accessibilityIdentifier("deletion-check")
                }
            }
            .padding(FanousScale.spacingMd)
            .fanousMaterial(.card) { .rounded($0.md) }
        }
    }

    static func text(_ record: DeletionRecord) -> String {
        switch record.stage {
        case .deleteSent where record.unsettled: "studio.deleteAccount.openSignedOutUnsettled"
        case .deleteSent: "studio.deleteAccount.openSignedOutUnknown"
        default: "studio.deleteAccount.openSignedOut"
        }
    }
}

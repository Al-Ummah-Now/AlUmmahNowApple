import AUNDesign
import SwiftUI

/// The current notice, if any, with a dismiss button.
struct NoticeView: View {
    @Environment(\.l10n) private var l10n
    @Bindable var session: StudioSession

    var body: some View {
        if let notice = session.notice {
            HStack(alignment: .firstTextBaseline, spacing: FanousScale.spacingSm) {
                Image(systemName: notice.isError ? "exclamationmark.circle" : "checkmark.circle").accessibilityHidden(true)
                Text(text(notice)).frame(maxWidth: .infinity, alignment: .leading)
                Button(l10n("common.dismiss")) { session.notice = nil }.buttonStyle(.borderless)
            }
            .fanousFont(.label)
            .foregroundStyle(notice.isError ? Fanous.errorText : Fanous.textPrimary)
            .padding(FanousScale.spacingMd)
            .fanousMaterial(.card) { .rounded($0.md) }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notice")
            .onAppear { AccessibilityNotification.Announcement(text(notice)).post() }
            .onChange(of: notice.id) { _, _ in AccessibilityNotification.Announcement(text(notice)).post() }
        }
    }

    private func text(_ notice: StudioNotice) -> String {
        guard let days = notice.purgeDays else { return l10n(notice.key) }
        let purge = l10n("studio.deleteAccount.donePurge", DisplayFormat.number(days, l10n.language))
        return "\(l10n(notice.key)) \(purge)"
    }
}

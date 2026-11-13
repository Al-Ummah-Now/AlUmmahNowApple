import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Approve, Reject, Request changes and Escalate, with ⌘⇧A, ⌘⇧R, ⌘⇧C and ⌘⇧E on a keyboard (never a bare key, which a search field could type). Offline every
/// button says so and nothing is queued for later.
struct ActionBar: View {
    @Environment(\.l10n) private var l10n
    let model: ReviewModel
    let isOffline: Bool
    @Binding var sheet: DecisionSheet.Kind?

    var body: some View {
        VStack(spacing: FanousScale.spacingSm) {
            if let message = model.message {
                Text(message).fanousFont(.label).foregroundStyle(Fanous.errorText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("decision-message")
            }
            if isOffline {
                Label(l10n("admin.offline.decide"), systemImage: "wifi.slash").fanousFont(.label)
                    .foregroundStyle(Fanous.textSecondary).accessibilityIdentifier("offline-decide")
            }
            if let item = model.item, item.isOpen {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: FanousScale.spacingSm) { buttons(item) }
                    VStack(spacing: FanousScale.spacingSm) { buttons(item) }
                }
                .disabled(isOffline || model.isDeciding)
            } else if let item = model.item, let decision = item.decision {
                Text(AdminText.decision(decision, by: item.decidedByName, l10n: l10n)).fanousFont(.label)
                    .foregroundStyle(Fanous.textSecondary).accessibilityIdentifier("decided")
            }
        }
        .padding(FanousScale.spacingMd)
        .background(Fanous.surface)
    }

    @ViewBuilder private func buttons(_ item: ReviewItem) -> some View {
        Button {
            Task { await model.decide(.approve) }
        } label: {
            Label(l10n("admin.action.approve"), systemImage: "checkmark.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(FanousButtonStyle(.primary))
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .accessibilityHint(l10n(item.escalate ? "admin.action.approve.stepUp" : "admin.action.approve.hint"))
        .accessibilityIdentifier("approve")
        Button {
            sheet = .reject
        } label: {
            Label(l10n("admin.action.reject"), systemImage: "xmark.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(FanousButtonStyle(.secondary))
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .accessibilityIdentifier("reject")
        Button {
            sheet = .requestChanges
        } label: {
            Label(l10n("admin.action.requestChanges"), systemImage: "pencil.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(FanousButtonStyle(.secondary))
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .accessibilityIdentifier("request-changes")
        if !item.escalate {
            Button {
                Task { await model.decide(.escalate) }
            } label: {
                Label(l10n("admin.action.escalate"), systemImage: "arrow.up.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(FanousButtonStyle(.ghost))
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .accessibilityIdentifier("escalate")
        }
    }
}

/// Reject with a reason (the fixed, admin-managed list) or Request changes with a note to the creator.
struct DecisionSheet: View {
    enum Kind: String, Identifiable {
        case reject, requestChanges
        var id: String { rawValue }
    }

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    let submit: (ReviewReason?, String) -> Void
    @State private var reason: ReviewReason?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                if kind == .reject {
                    Section(l10n("admin.sheet.reason")) {
                        ForEach(ReviewReason.allCases) { option in
                            Button {
                                reason = option
                            } label: {
                                HStack {
                                    Text(l10n("admin.reason.\(option.rawValue)")).foregroundStyle(Fanous.textPrimary)
                                    Spacer()
                                    if reason == option {
                                        Image(systemName: "checkmark").foregroundStyle(Fanous.accent)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .accessibilityAddTraits(reason == option ? [.isSelected] : [])
                            .accessibilityIdentifier("reason-\(option.rawValue)")
                        }
                    }
                }
                Section(l10n(kind == .reject ? "admin.sheet.noteOptional" : "admin.sheet.changes")) {
                    TextField(l10n("admin.sheet.notePlaceholder"), text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("decision-note")
                }
                Section {
                    Text(l10n("admin.sheet.creatorSees")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                }
            }
            .navigationTitle(l10n(kind == .reject ? "admin.action.reject" : "admin.action.requestChanges"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n("common.cancel")) { dismiss() }.accessibilityIdentifier("sheet-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n("admin.sheet.send")) {
                        dismiss()
                        submit(reason, note)
                    }
                    .disabled(!canSend)
                    .accessibilityIdentifier("sheet-send")
                }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    private var canSend: Bool {
        switch kind {
        case .reject: reason != nil
        case .requestChanges: !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// The toast at the bottom of the window (Undo for 10 s).
struct ToastView: View {
    @Environment(\.l10n) private var l10n
    let center: ToastCenter

    var body: some View {
        if let toast = center.toast {
            HStack(spacing: FanousScale.spacingMd) {
                Text(toast.text).fanousFont(.label)
                    .foregroundStyle(toast.isError ? Fanous.errorText : Fanous.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let action = toast.actionTitle {
                    Button(action) { Task { await center.perform() } }
                        .buttonStyle(FanousButtonStyle(.secondary))
                        .keyboardShortcut("z", modifiers: .command)
                        .accessibilityIdentifier("toast-action")
                }
                Button {
                    center.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(l10n("common.dismiss"))
            }
            .padding(FanousScale.spacingMd)
            .fanousMaterial(.raised) { .rounded($0.md) }
            .padding(FanousScale.spacingLg)
            .frame(maxWidth: 560)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toast")
            .onAppear { AccessibilityNotification.Announcement(toast.text).post() }
        }
    }
}

import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Confirms deleting an account, in the app (App Store 5.1.1(v), never a system alert). Cancel has focus first and there is
/// always a way out: while a request is out the button stops the deletion after it. The action needs the typed word.
struct DeleteAccountSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @FocusState private var cancelFocused: Bool
    @AccessibilityFocusState private var cancelSpoken: Bool
    @State private var model: DeleteAccountModel
    @State private var typed = ""
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 14

    /// The sign-in record is purged this many days after the deletion (Auth).
    private static let purgeDays = 30

    private let session: StudioSession
    private let onDeleted: () -> Void

    init(account: StudioAccount, session: StudioSession, onDeleted: @escaping () -> Void) {
        _model = State(initialValue: DeleteAccountModel(account: account, session: session))
        self.session = session
        self.onDeleted = onDeleted
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: FanousScale.spacingLg) {
                    heading
                    consequences
                    wordField
                    status.id("status")
                    ViewThatFits {
                        HStack(spacing: FanousScale.spacingMd) { buttons }
                        VStack(spacing: FanousScale.spacingMd) { buttons }
                    }
                    .id("buttons")
                }
                .multilineTextAlignment(.center)
                .padding(FanousScale.spacingXl)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            // What happens is said at the end: at a large text size that is below the fold.
            .onChange(of: model.message) { _, _ in scroll.scrollTo("buttons", anchor: .bottom) }
            .onChange(of: model.working) { _, _ in scroll.scrollTo("buttons", anchor: .bottom) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .interactiveDismissDisabled(model.working || session.isSigningIn)
        .onAppear {
            cancelFocused = true
            cancelSpoken = true
        }
        .onChange(of: model.end) { _, end in
            guard let end else { return }
            dismiss()
            if end == .deleted { onDeleted() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fanousPage()
        .environment(\.layoutDirection, l10n.language.isRTL ? .rightToLeft : .leftToRight)
        #if os(iOS)
            .presentationDetents([.large])
            .presentationBackground { FanousSurfaceKind(kind: .page, shape: .rect) }
        #elseif os(macOS)
            .frame(minWidth: 440, minHeight: 560)
        #endif
    }

    @ViewBuilder private var heading: some View {
        Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(Fanous.errorText)
            .accessibilityHidden(true)
        Text(l10n("studio.deleteAccount.title"))
            .font(.system(size: titleSize, weight: .bold))
            .foregroundStyle(Fanous.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 2) {
            if let name = model.account.name, name != model.account.email {
                Text(DisplayFormat.isolate(name)).font(.system(size: bodySize, weight: .semibold))
                    .foregroundStyle(Fanous.textPrimary)
            }
            if let email = model.account.email {
                OneLineAddress(email).font(.system(size: labelSize)).foregroundStyle(Fanous.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("delete-account-name")
    }

    @ViewBuilder private var consequences: some View {
        if let record = session.openDeletion(of: model.account.id), model.message == nil, !model.working {
            Text(l10n(DeletionBanner.text(record)))
                .font(.system(size: labelSize, weight: .medium))
                .foregroundStyle(Fanous.errorText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(FanousScale.spacingMd)
                .frame(maxWidth: .infinity)
                .fanousMaterial(.card) { .rounded($0.md) }
                .accessibilityIdentifier("delete-account-pending-banner")
        }
        Group {
            Text(l10n("studio.deleteAccount.body")).foregroundStyle(Fanous.textPrimary)
            if let channels = ownedChannels {
                Text(channels).fontWeight(.semibold).foregroundStyle(Fanous.textPrimary)
                    .accessibilityIdentifier("delete-account-owned-channels")
            }
            Text(l10n("studio.deleteAccount.kept", DisplayFormat.number(Self.purgeDays, l10n.language)))
                .foregroundStyle(Fanous.textSecondary)
        }
        .font(.system(size: bodySize))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The number when it is known, else the general sentence; nothing when the account owns none.
    private var ownedChannels: String? {
        guard let owned = session.ownedChannelCount else { return l10n("studio.deleteAccount.channels") }
        guard owned > 0 else { return nil }
        let category = DisplayFormat.pluralCategory(owned, l10n.language)
        return l10n("studio.deleteAccount.channels.\(category)", DisplayFormat.number(owned, l10n.language))
    }

    private var wordField: some View {
        let label = l10n(
            "studio.deleteAccount.confirmLabel", DisplayFormat.isolate(l10n("studio.deleteAccount.confirmWord")))
        return VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            Text(label)
                .font(.system(size: labelSize, weight: .medium))
                .foregroundStyle(Fanous.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            TextField(
                "", text: $typed,
                prompt: Text(l10n("studio.deleteAccount.confirmWord")).foregroundStyle(Fanous.part(\.formPlaceholder))
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.characters)
            #endif
            .disabled(model.working)
            .accessibilityLabel(label)
            .accessibilityIdentifier("delete-account-confirm-input")
        }
    }

    @ViewBuilder private var status: some View {
        if model.working {
            ProgressView(progress)
                .tint(Fanous.textPrimary)
                .foregroundStyle(Fanous.textPrimary)
                .accessibilityIdentifier("delete-account-progress")
        } else if let message = model.message {
            SwiftUI.TimelineView(.periodic(from: .now, by: 5)) { time in
                VStack(spacing: FanousScale.spacingXs) {
                    Text(l10n(message))
                    if let wait = waitText(now: time.date) {
                        Text(wait).accessibilityIdentifier("delete-account-wait")
                    }
                }
                .font(.system(size: labelSize, weight: .medium))
                .foregroundStyle(model.isError ? Fanous.errorText : Fanous.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(FanousScale.spacingMd)
                .frame(maxWidth: .infinity)
                .fanousMaterial(.card) { .rounded($0.md) }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("delete-account-message")
            }
            .onAppear { AccessibilityNotification.Announcement(l10n(message)).post() }
            .onChange(of: message) { _, new in AccessibilityNotification.Announcement(l10n(new)).post() }
        }
    }

    private var progress: String {
        if model.restarted { return l10n("studio.deleteAccount.restarted") }
        guard model.passes > 0 else { return l10n("studio.deleteAccount.progress") }
        return l10n("studio.deleteAccount.pass", DisplayFormat.number(model.passes + 1, l10n.language))
    }

    /// Never less than is left: minutes and hours are rounded up.
    private func waitText(now: Date) -> String? {
        guard let until = model.notBefore, until > now else { return nil }
        let minutes = Int((until.timeIntervalSince(now) / 60).rounded(.up))
        let (count, unit) = minutes < 120 ? (minutes, "minutes") : ((minutes + 59) / 60, "hours")
        let category = DisplayFormat.pluralCategory(count, l10n.language)
        return l10n("studio.deleteAccount.wait.\(unit).\(category)", DisplayFormat.number(count, l10n.language))
    }

    @ViewBuilder private var buttons: some View {
        cancelButton
        SwiftUI.TimelineView(.periodic(from: .now, by: 5)) { time in actionButton(now: time.date) }
    }

    @ViewBuilder private var cancelButton: some View {
        let title =
            model.stopping
            ? "studio.deleteAccount.stopping" : model.working ? "studio.deleteAccount.stop" : "common.cancel"
        let button = Button {
            if model.cancel() { dismiss() }
        } label: {
            Text(l10n(title)).font(.system(size: labelSize, weight: .semibold))
        }
        .keyboardShortcut(.cancelAction)
        .focused($cancelFocused)
        .accessibilityFocused($cancelSpoken)
        .accessibilityIdentifier("delete-account-cancel")
        if model.stopping {
            button.buttonStyle(ReadableDisabledStyle()).disabled(true)
        } else {
            button.buttonStyle(FanousButtonStyle(.primary)).disabled(session.isSigningIn)
        }
    }

    @ViewBuilder private func actionButton(now: Date) -> some View {
        let title =
            switch model.action {
            case .delete: "studio.deleteAccount.action"
            case .signIn: "studio.deleteAccount.signInAction"
            case .deleteAnyway: "studio.deleteAccount.anyway"
            }
        let button = Button(role: model.action == .signIn ? nil : .destructive) {
            Task { await model.act() }
        } label: {
            Text(l10n(title)).font(.system(size: labelSize, weight: .semibold))
                .foregroundStyle(
                    !model.canAct(typed: typed, now: now) || model.action == .signIn
                        ? Fanous.textPrimary : Fanous.errorText)
        }
        .accessibilityIdentifier("delete-account-confirm")
        if model.canAct(typed: typed, now: now) {
            button.buttonStyle(FanousButtonStyle(.secondary))
        } else {
            button.buttonStyle(ReadableDisabledStyle()).disabled(true)
        }
    }
}

/// An email address on one line: it never breaks inside the domain. Too long for the line, its middle is left out.
struct OneLineAddress: View {
    private let address: String

    init(_ address: String) { self.address = address }

    var body: some View {
        Text(DisplayFormat.isolate(address)).lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.7)
            .accessibilityLabel(address)
    }
}

/// A disabled button whose text can still be read: the shared style fades it to 2:1.
private struct ReadableDisabledStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fanousFont(.label)
            .foregroundStyle(Fanous.textPrimary)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(Capsule().fill(Fanous.surfaceRaised))
            .overlay(Capsule().strokeBorder(Fanous.textSecondary, lineWidth: 1))
    }
}

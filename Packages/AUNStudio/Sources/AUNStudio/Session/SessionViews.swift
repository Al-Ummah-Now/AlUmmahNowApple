import AUNCoreBridge
import AUNDesign
import SwiftUI

/// The first screen when no account is signed in.
struct SignInView: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession

    var body: some View {
        ScrollView {
            VStack(spacing: FanousScale.spacingLg) {
                FanousMotif(.loader).frame(width: 64, height: 64).accessibilityHidden(true)
                Text(l10n("studio.name")).fanousFont(.label).foregroundStyle(Fanous.accent)
                Text(l10n("studio.signIn.title")).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(l10n("studio.signIn.message")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                if session.isSigningIn {
                    ProgressView(l10n("studio.signIn.progress")).accessibilityIdentifier("sign-in-progress")
                } else {
                    Button {
                        Task { await session.signIn() }
                    } label: {
                        Label(l10n("studio.signIn.button"), systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: 280)
                    }
                    .buttonStyle(FanousButtonStyle(.primary))
                    .accessibilityIdentifier("sign-in")
                }
                NoticeView(session: session)
            }
            .multilineTextAlignment(.center)
            .padding(FanousScale.spacingXl)
            .frame(maxWidth: 460)
            .fanousMaterial(.raised) { .rounded($0.xl) }
            .padding(FanousScale.spacingLg)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .fanousPage()
    }
}

/// The current notice, if any, with a dismiss button.
struct NoticeView: View {
    @Environment(\.l10n) private var l10n
    @Bindable var session: StudioSession

    var body: some View {
        if let notice = session.notice {
            HStack(alignment: .firstTextBaseline, spacing: FanousScale.spacingSm) {
                Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                Text(l10n(notice.key)).frame(maxWidth: .infinity, alignment: .leading)
                Button(l10n("common.dismiss")) { session.notice = nil }.buttonStyle(.borderless)
            }
            .fanousFont(.label)
            .foregroundStyle(Fanous.errorText)
            .padding(FanousScale.spacingMd)
            .fanousMaterial(.card) { .rounded($0.md) }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notice")
        }
    }
}

/// A destructive action explained in the app, with Cancel focused (for keyboard, Full Keyboard Access and VoiceOver).
/// Shared with the Admin app (ban, remove, suspend, sign out).
public struct ConfirmSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @FocusState private var cancelFocused: Bool
    @AccessibilityFocusState private var cancelSpoken: Bool

    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    public init(title: String, message: String, actionTitle: String, action: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: FanousScale.spacingLg) {
                Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(Fanous.errorText)
                    .accessibilityHidden(true)
                Text(title).fanousFont(.title).foregroundStyle(Fanous.textPrimary).accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                // Never truncated: the explanation is the point of the sheet.
                Text(message).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits {
                    HStack(spacing: FanousScale.spacingMd) { buttons }
                    VStack(spacing: FanousScale.spacingMd) { buttons }
                }
            }
            .multilineTextAlignment(.center)
            .padding(FanousScale.spacingXl)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            cancelFocused = true
            cancelSpoken = true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fanousPage()
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationBackground { FanousSurfaceKind(kind: .page, shape: .rect) }
        #endif
    }

    @ViewBuilder private var buttons: some View {
        Button(l10n("common.cancel")) { dismiss() }
            .buttonStyle(FanousButtonStyle(.primary))
            .keyboardShortcut(.cancelAction)
            .focused($cancelFocused)
            .accessibilityFocused($cancelSpoken)
            .accessibilityIdentifier("confirm-cancel")
        Button(role: .destructive) {
            dismiss()
            action()
        } label: {
            Text(actionTitle).foregroundStyle(Fanous.errorText)
        }
        .buttonStyle(FanousButtonStyle(.secondary))
        .accessibilityIdentifier("confirm-action")
    }
}

/// Signed-in accounts: switch, add, and sign out (each with an in-app confirmation).
struct AccountsView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    let session: StudioSession
    @State private var leaving: StudioAccount?

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
                    .disabled(session.isSigningIn)
                    .accessibilityIdentifier("account-add")
                }
                .studioRows()
                if session.notice != nil { Section { NoticeView(session: session) } }
            }
            .scrollContentBackground(.hidden)
            .fanousPage()
            .navigationTitle(l10n("studio.account.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n("common.dismiss")) { dismiss() }.accessibilityIdentifier("accounts-done")
                }
            }
        }
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
                            Text(email).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
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
            .accessibilityHint(isActive ? "" : l10n("studio.account.switch", account.label))
            .accessibilityIdentifier("account-\(account.id)")
            Button(l10n("studio.account.signOut")) { leaving = account }
                .buttonStyle(.borderless)
                .foregroundStyle(Fanous.errorText)
                .accessibilityIdentifier("account-sign-out-\(account.id)")
        }
    }
}

/// A round avatar with the first letter as a fallback.
struct AvatarView: View {
    let name: String
    let url: URL?
    var size: Double = 36

    var body: some View {
        ZStack {
            Circle().fill(Fanous.surfaceRaised)
            Text(String(name.prefix(1)).uppercased()).fanousFont(.label).foregroundStyle(Fanous.accent)
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Fanous.outline, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Every channel the person may upload to; the pick is remembered per account.
struct ChannelPicker: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession

    var body: some View {
        Menu {
            ForEach(session.channels) { channel in
                Button {
                    Task { await session.select(channel) }
                } label: {
                    if channel.id == session.channel?.id {
                        Label(title(channel), systemImage: "checkmark")
                    } else {
                        Text(title(channel))
                    }
                }
                .accessibilityIdentifier("channel-\(channel.id)")
            }
        } label: {
            HStack(spacing: FanousScale.spacingSm) {
                AvatarView(
                    name: session.channel?.displayName(l10n.language) ?? "?", url: session.channel?.avatarURL, size: 24)
                Text(session.channel?.displayName(l10n.language) ?? l10n("studio.channel.pick"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 230, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down").font(.caption).accessibilityHidden(true)
            }
        }
        .disabled(session.channels.isEmpty)
        .accessibilityLabel(l10n("studio.channel.title"))
        .accessibilityValue(session.channel?.displayName(l10n.language) ?? l10n("studio.channel.pick"))
        .accessibilityIdentifier("channel-picker")
    }

    private func title(_ channel: StudioChannel) -> String {
        "\(channel.displayName(l10n.language)) · \(l10n("studio.role.\(channel.role.rawValue)"))"
    }
}

/// Opens the accounts sheet from a toolbar.
struct AccountButton: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession
    @Binding var showing: Bool

    var body: some View {
        Button {
            showing = true
        } label: {
            AvatarView(name: session.account?.label ?? "?", url: session.account?.avatarURL, size: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l10n("studio.account.menu"))
        .accessibilityValue(session.account?.label ?? "")
        .accessibilityIdentifier("account-button")
    }
}

/// Dashboard header: the channel being worked in, and who is signed in.
struct StudioHomeView: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession

    var body: some View {
        Group {
            switch session.channelsState {
            case .idle, .loading:
                ThemeLoader()
            case .failed:
                ErrorStateView { Task { await session.loadChannels() } }
            case .loaded:
                if let channel = session.channel {
                    ScrollView {
                        VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                            channelCard(channel)
                            NoticeView(session: session)
                        }
                        .padding(FanousScale.spacingLg)
                        .frame(maxWidth: 900, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    EmptyStateView(title: l10n("studio.channel.none"), message: l10n("studio.channel.noneMessage"))
                        .accessibilityIdentifier("no-channels")
                }
            }
        }
        .fanousPage()
    }

    private func channelCard(_ channel: StudioChannel) -> some View {
        HStack(spacing: FanousScale.spacingLg) {
            AvatarView(name: channel.displayName(l10n.language), url: channel.avatarURL, size: 56)
            VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                Text(channel.displayName(l10n.language)).fanousFont(.title).foregroundStyle(Fanous.textPrimary)
                if let handle = channel.handle {
                    Text(verbatim: "@\(handle)").fanousFont(.label).foregroundStyle(Fanous.textSecondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Text(l10n("studio.role.\(channel.role.rawValue)")).fanousFont(.caption).foregroundStyle(Fanous.accent)
                if let account = session.account {
                    Text(l10n("studio.home.signedInAs", account.label)).fanousFont(.caption)
                        .foregroundStyle(Fanous.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(FanousScale.spacingLg)
        .fanousMaterial(.card) { .rounded($0.lg) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("channel-card")
    }
}

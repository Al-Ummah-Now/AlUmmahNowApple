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
                SignedOutDeletions(session: session)
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
        .environment(\.layoutDirection, l10n.language.isRTL ? .rightToLeft : .leftToRight)
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
    @State private var deleting: StudioAccount?

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

/// A round avatar with the first letter as a fallback.
struct AvatarView: View {
    let name: String
    let url: URL?
    var size: Double = 36
    /// The hairline ring; the header avatar has none, as on the web (owner, 2026-11-13).
    var ring = true

    var body: some View {
        ZStack {
            Circle().fill(Fanous.surfaceRaised)
            Text(Self.initial(of: name)).fanousFont(.label).foregroundStyle(Fanous.accent)
                .dynamicTypeSize(...DynamicTypeSize.large)
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay { if ring { Circle().strokeBorder(Fanous.outline, lineWidth: 1) } }
        .accessibilityHidden(true)
    }

    /// The first letter of the first word; an Arabic «ال» article is skipped when the word is longer than it
    /// («الأمة الآن» → «أ», not «ا»). Latin names keep their first letter, upper-cased.
    nonisolated static func initial(of name: String) -> String {
        let word = name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let stem = word.hasPrefix("ال") && word.count > 2 ? String(word.dropFirst(2)) : word
        return String(stem.prefix(1)).uppercased()
    }
}

/// The one identity control (owner rule: identity only in the navigation). Its label is the channel being acted as;
/// it opens one menu: the signed-in person, every channel they may upload to with their role (the pick is remembered
/// per account), then Accounts (switch, add, sign in again, sign out).
struct IdentityMenu: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession
    @Binding var showingAccounts: Bool
    var style: Style = .avatar

    enum Style { case avatar, sidebar }

    var body: some View {
        Menu {
            Section(session.account?.label ?? "") {
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
            }
            Section {
                StudioSupportLinksSection(environment: session.environment, idPrefix: "identity")
            }
            Section {
                Button {
                    showingAccounts = true
                } label: {
                    Label(l10n("studio.account.title"), systemImage: "person.2")
                }
                .accessibilityIdentifier("accounts-manage")
            }
        } label: {
            label
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(l10n("studio.identity.menu"))
        .accessibilityValue(value)
        .accessibilityIdentifier("account-button")
    }

    @ViewBuilder private var label: some View {
        let name = session.channel?.displayName(l10n.language) ?? session.account?.label ?? "?"
        let url = session.channel?.avatarURL ?? session.account?.avatarURL
        switch style {
        case .avatar:
            AvatarView(name: name, url: url, size: 32, ring: false)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        case .sidebar:
            HStack(spacing: FanousScale.spacingSm) {
                AvatarView(name: name, url: url, size: 32, ring: false)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).fanousFont(.label).fontWeight(.semibold).foregroundStyle(Fanous.textPrimary).lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let role = session.channel?.role {
                        Text(l10n("studio.role.\(role.rawValue)")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Fanous.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(FanousScale.spacingSm)
            .fanousMaterial(.card) { .rounded($0.lg) }
            .contentShape(Rectangle())
        }
    }

    /// The channel, the role in it and who is signed in, for VoiceOver and tests.
    private var value: String {
        guard let channel = session.channel else { return session.account?.label ?? l10n("studio.channel.pick") }
        return DisplayFormat.meta(
            [channel.displayName(l10n.language), l10n("studio.role.\(channel.role.rawValue)"), session.account?.label ?? ""]
                .filter { !$0.isEmpty }, l10n.language)
    }

    private func title(_ channel: StudioChannel) -> String {
        DisplayFormat.meta([channel.displayName(l10n.language), l10n("studio.role.\(channel.role.rawValue)")], l10n.language)
    }
}

/// Dashboard: the channel being worked in and who is signed in, then what needs attention (recent uploads and their
/// processing, comments awaiting review, drafts and scheduled videos). A section whose feature is off is not shown.
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
                    DashboardContent(session: session, channel: channel).id(channel.id)
                } else {
                    EmptyStateView(title: l10n("studio.channel.none"), message: l10n("studio.channel.noneMessage"))
                        .accessibilityIdentifier("no-channels")
                }
            }
        }
        .fanousPage()
    }
}

/// One channel's Dashboard; rebuilt when the channel changes.
struct DashboardContent: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession
    let channel: StudioChannel
    @State private var model: DashboardModel
    @ScaledMetric(relativeTo: .caption) private var kpiWidth: CGFloat = 120

    init(session: StudioSession, channel: StudioChannel) {
        self.session = session
        self.channel = channel
        let model = DashboardModel(channel: channel, services: session.services)
        model.onHollow = { [weak session] in session?.featureOff(.home) }
        model.onFeatureOff = { [weak session] in Task { await session?.refreshFeatures() } }
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                if session.notice?.isAboutDeletion != true { NoticeView(session: session) }
                if !model.counts.isEmpty { kpis }
                // The full width (no reading cap): one column on iPhone, two on iPad, three on Mac.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 320), spacing: FanousScale.spacingLg, alignment: .top)],
                    alignment: .leading, spacing: FanousScale.spacingLg
                ) {
                    recentSection
                    heldSection
                    queueSection
                }
            }
            .padding(FanousScale.spacingLg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await model.load() }
        .task { if model.recentPhase == .idle { await model.load() } }
    }

    @ViewBuilder private var recentSection: some View {
        DashboardSection(
            title: l10n("studio.home.recent"), phase: model.recentPhase, empty: l10n("studio.home.recentEmpty"),
            identifier: "dashboard-recent", seeAll: openContent, retry: { Task { await model.loadRecent() } }
        ) {
            ForEach(model.recent) { VideoRow(video: $0, showsStatus: true) }
        }
    }

    @ViewBuilder private var heldSection: some View {
        DashboardSection(
            title: l10n("studio.home.held"), phase: model.heldPhase, empty: l10n("studio.home.heldEmpty"),
            identifier: "dashboard-held", retry: { Task { await model.loadHeld() } }
        ) {
            Text(l10n("studio.home.heldCount", DisplayFormat.count(model.held.total, l10n.language)))
                .fanousFont(.label).foregroundStyle(Fanous.accent)
            ForEach(model.held.items) { HeldCommentRow(comment: $0) }
        }
    }

    @ViewBuilder private var queueSection: some View {
        DashboardSection(
            title: l10n("studio.home.queue"), phase: model.queuePhase, empty: l10n("studio.home.queueEmpty"),
            identifier: "dashboard-queue", seeAll: openContent, retry: { Task { await model.loadQueue() } }
        ) {
            Text(queueSummary).fanousFont(.label).foregroundStyle(Fanous.accent)
            ForEach(model.scheduled + model.drafts) { VideoRow(video: $0, showsStatus: true) }
        }
    }

    private var kpis: some View {
        let tiles = ForEach(StudioStatus.allCases, id: \.self) { status in
            KPITile(label: l10n("studio.tab.\(status.rawValue)"), value: model.counts[status] ?? 0, alert: status == .failed)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: FanousScale.spacingMd) { tiles }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FanousScale.spacingMd) { tiles.frame(width: kpiWidth) }
                    .padding(.vertical, FanousScale.spacingSm)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard-counts")
    }

    private var queueSummary: String {
        let language = l10n.language
        let drafts = model.counts[.drafts] ?? model.drafts.count
        let scheduled = model.counts[.scheduled] ?? model.scheduled.count
        return DisplayFormat.meta(
            [
                "\(l10n("studio.tab.drafts")) \(DisplayFormat.count(drafts, language))",
                "\(l10n("studio.tab.scheduled")) \(DisplayFormat.count(scheduled, language))",
            ], language)
    }

    private func openContent() { Task { await session.open(StudioLink(section: .content)) } }
}

/// One Dashboard card: its title, then a spinner while it loads, its rows, a plain empty line, or Retry. Hidden
/// sections draw nothing.
struct DashboardSection<Rows: View>: View {
    @Environment(\.l10n) private var l10n
    let title: String
    let phase: LoadPhase
    let empty: String
    let identifier: String
    var seeAll: (() -> Void)?
    let retry: () -> Void
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        if phase != .hidden {
            Group {
                if let seeAll, phase == .ready {
                    // Owner rule: a card's buttons sit in its footer, at the trailing end.
                    FanousCard {
                        content
                    } actions: {
                        Button(l10n("studio.home.seeAll"), action: seeAll)
                            .buttonStyle(FanousButtonStyle(.ghost))
                            .accessibilityIdentifier("\(identifier)-all")
                    }
                } else {
                    FanousCard { content }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
            Text(title).fanousFont(.title).foregroundStyle(Fanous.textPrimary).accessibilityAddTraits(.isHeader)
            switch phase {
            case .loading:
                ProgressView().accessibilityLabel(l10n("common.loading")).frame(maxWidth: .infinity)
            case .ready:
                rows()
            case .empty:
                Text(empty).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
                    .accessibilityIdentifier("\(identifier)-empty")
            case .failed:
                VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                    Text(l10n("common.error.load")).fanousFont(.body).foregroundStyle(Fanous.errorText)
                    Button(l10n("common.retry"), action: retry)
                }
            case .idle, .hidden:
                EmptyView()
            }
        }
    }
}

/// A count tile: the number large, the status under it, in the card material.
struct KPITile: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var countSize: CGFloat = 26
    let label: String
    let value: Int
    var alert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DisplayFormat.number(value, l10n.language))
                .font(.system(size: countSize, weight: .bold)).monospacedDigit()
                .foregroundStyle(alert && value > 0 ? Fanous.errorText : Fanous.textPrimary)
            Text(label).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
        }
        .padding(FanousScale.spacingMd)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fanousMaterial(.card) { .rounded($0.lg) }
        .accessibilityElement(children: .combine)
    }
}

/// A held comment: who wrote it, where, and its text.
struct HeldCommentRow: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let comment: HeldComment

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            Text(comment.authorName).fanousFont(.label).foregroundStyle(Fanous.textPrimary)
            Text(comment.text).fanousFont(.body).foregroundStyle(Fanous.textPrimary).lineLimit(3)
            Text(comment.displayTargetTitle(l10n.language)).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("held-\(comment.id)")
    }
}

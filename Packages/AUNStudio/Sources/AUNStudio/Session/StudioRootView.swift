import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Studio's window content on iPhone, iPad and Mac: sign-in until an account is active, then the Studio shell.
public struct StudioRootView: View {
    @State private var session: StudioSession

    /// `preferences` holds per-device choices such as the last channel per account.
    public init(services: StudioServices, authenticator: any WebAuthenticating, preferences: UserDefaults = .standard) {
        _session = State(
            initialValue: StudioSession(services: services, authenticator: authenticator, defaults: preferences))
    }

    public var body: some View {
        Group {
            switch session.phase {
            case .loading: ThemeLoader().frame(maxWidth: .infinity, maxHeight: .infinity).fanousPage()
            case .signedOut: SignInView(session: session)
            case .signedIn: StudioShell(session: session)
            }
        }
        .task { await session.start() }
    }
}

/// Channel and account controls shared by both shells.
struct StudioToolbar: ToolbarContent {
    let session: StudioSession
    @Binding var showingAccounts: Bool

    var body: some ToolbarContent {
        #if os(iOS)
            // Leading, not centred: a long channel name then truncates instead of running into the account button.
            ToolbarItem(placement: .topBarLeading) { ChannelPicker(session: session) }
        #else
            ToolbarItem(placement: .principal) { ChannelPicker(session: session) }
        #endif
        ToolbarItem(placement: .primaryAction) { AccountButton(session: session, showing: $showingAccounts) }
    }
}

extension View {
    /// A solid bar in the theme's page colour, so content never shows through the channel picker as it scrolls.
    func studioNavigationBar() -> some View {
        #if os(iOS)
            modifier(SolidNavigationBar())
        #else
            self
        #endif
    }
}

#if os(iOS)
    private struct SolidNavigationBar: ViewModifier {
        func body(content: Content) -> some View {
            let solid =
                content
                .toolbarBackground(Fanous.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            if #available(iOS 26, *) {
                solid.scrollEdgeEffectStyle(.hard, for: .top)
            } else {
                solid
            }
        }
    }
#endif

/// The account's state, once, above every Studio screen: writes are refused until an admin acts. The app reads
/// `GET /api/me/creator` again when it comes to the foreground, so a restore lifts it.
struct AccountStateBanner: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.scenePhase) private var scenePhase
    let session: StudioSession

    var body: some View {
        Group {
            if let state = session.accountState {
                Label {
                    VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                        Text(l10n("studio.account.stateTitle")).fanousFont(.label).foregroundStyle(Fanous.textPrimary)
                        Text(l10n(StudioFailure.refusalMessage(state).key)).fanousFont(.body)
                            .foregroundStyle(Fanous.textSecondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Fanous.errorText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(FanousScale.spacingMd)
                .fanousMaterial(.raised) { .rounded($0.md) }
                .padding(.horizontal, FanousScale.spacingLg)
                .padding(.vertical, FanousScale.spacingSm)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account-state")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.refreshCreatorAccess() } }
        }
    }
}

/// Shows a channel's screen, rebuilt when the channel changes, or the "no channel" state.
struct ChannelGate<Content: View>: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        if let channel = session.channel {
            content(channel.id).id(channel.id)
        } else {
            EmptyStateView(title: l10n("studio.channel.none"), message: l10n("studio.channel.noneMessage")).fanousPage()
        }
    }
}

#if os(iOS)
    struct StudioShell: View {
        @Environment(\.l10n) private var l10n
        let session: StudioSession
        @State private var showingAccounts = false

        var body: some View {
            tabs
                .safeAreaInset(edge: .top, spacing: 0) { AccountStateBanner(session: session) }
                .sheet(isPresented: $showingAccounts) { AccountsView(session: session) }
        }

        private func screen(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
            NavigationStack {
                content()
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { StudioToolbar(session: session, showingAccounts: $showingAccounts) }
                    .studioNavigationBar()
            }
        }

        private var tabs: some View {
            TabView {
                screen(l10n("studio.home.title")) { StudioHomeView(session: session) }
                    .tabItem { Label(l10n("studio.home.title"), systemImage: "square.grid.2x2") }
                screen(l10n("studio.content.title")) {
                    ChannelGate(session: session) { channel in ContentView(session: session, channelID: channel) }
                }
                .tabItem { Label(l10n("studio.content.title"), systemImage: "film.stack") }
                screen(l10n("studio.upload.title")) { UploadView(session: session) }
                    .tabItem { Label(l10n("studio.upload.title"), systemImage: "square.and.arrow.up") }
                    .badge(session.uploads.jobs.filter { $0.isActive && $0.accountID == session.account?.id }.count)
                screen(l10n("studio.analytics.title")) {
                    ChannelGate(session: session) { channel in AnalyticsView(services: session.services, channelID: channel) }
                }
                .tabItem { Label(l10n("studio.analytics.title"), systemImage: "chart.bar") }
                NavigationStack { MobileEditorView() }
                    .tabItem { Label(l10n("studio.editor.title"), systemImage: "scissors") }
            }
        }
    }
#elseif os(macOS)
    struct StudioShell: View {
        @Environment(\.l10n) private var l10n
        let session: StudioSession
        @State private var section: StudioSection? = .home
        @State private var showingAccounts = false
        @State private var encodes = EncodeQueue(
            outputDirectory: URL.moviesDirectory.appending(path: "Al Ummah Now Studio"))

        var body: some View {
            NavigationSplitView {
                List(StudioSection.allCases, selection: $section) { item in
                    Label(l10n(item.titleKey), systemImage: item.icon)
                        .tag(item)
                        .accessibilityIdentifier("section-\(item.rawValue)")
                }
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            } detail: {
                NavigationStack {
                    Group {
                        switch section ?? .home {
                        case .home: StudioHomeView(session: session)
                        case .content:
                            ChannelGate(session: session) { ContentView(session: session, channelID: $0) }
                        case .deleted:
                            ChannelGate(session: session) { RecentlyDeletedView(services: session.services, channelID: $0) }
                        case .upload: UploadView(session: session)
                        case .analytics:
                            ChannelGate(session: session) { AnalyticsView(services: session.services, channelID: $0) }
                        case .encode: EncodeQueueView(queue: encodes)
                        case .editor: EditorView()
                        }
                    }
                    .toolbar { StudioToolbar(session: session, showingAccounts: $showingAccounts) }
                    .safeAreaInset(edge: .top, spacing: 0) { AccountStateBanner(session: session) }
                }
            }
            .frame(minWidth: 960, minHeight: 600)
            .sheet(isPresented: $showingAccounts) { AccountsView(session: session) }
        }
    }
#endif

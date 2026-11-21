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
        // Universal links on the videos host (`/studio/…`, `/app/studio/…`); the viewer's links are not Studio's.
        .onOpenURL { url in
            guard case .studio(let link) = AppLink.parse(url) else { return }
            Task { await session.open(link) }
        }
    }
}

/// The iPhone and iPad header: the screen title at the leading edge in the header's text colour, the identity menu
/// (the only identity control) at the trailing edge. The Mac keeps identity at the head of its sidebar.
struct StudioToolbar: ToolbarContent {
    let title: String
    let session: StudioSession
    @Binding var showingAccounts: Bool

    #if os(iOS)
        private var identity: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) { IdentityMenu(session: session, showingAccounts: $showingAccounts) }
        }
    #endif

    var body: some ToolbarContent {
        #if os(iOS)
            // The title is the bar's own (large, leading, in navText via FanousHeaderText); a custom leading item was
            // squeezed into a "…" bubble by the iOS 26 toolbar.
            if #available(iOS 26, *) {
                identity.sharedBackgroundVisibility(.hidden)
            } else {
                identity
            }
        #else
            // The title is text on the header, not a control: no glass capsule behind it on macOS 26.
            if #available(macOS 26, *) {
                macTitle.sharedBackgroundVisibility(.hidden)
            } else {
                macTitle
            }
        #endif
    }

    #if os(macOS)
        private var macTitle: some ToolbarContent { ToolbarItem(placement: .navigation) { FanousHeaderTitle(title) } }
    #endif
}

extension View {
    /// The web header on the bar (opaque), so content never shows through the bar's controls as it scrolls.
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
            // Every Studio screen, pushed ones included, uses the same large leading title (a pushed screen left on the
            // automatic mode drew no visible title on the iOS 26 header).
            let solid = content.toolbarTitleDisplayMode(.inlineLarge).fanousHeaderBar()
            if #available(iOS 26, *) {
                // Hard edges: scrolled text never shows through the header or the glass tab bar.
                solid.scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
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
                        Text(l10n(StudioFailure.refusalMessage(state) ?? "studio.error.generic")).fanousFont(.body)
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
        enum Tab: Hashable { case home, content, upload, analytics, editor }

        @Environment(\.l10n) private var l10n
        let session: StudioSession
        @State private var showingAccounts = false
        @State private var tab: Tab = .home

        var body: some View {
            tabs
                .safeAreaInset(edge: .top, spacing: 0) { AccountStateBanner(session: session) }
                .sheet(isPresented: $showingAccounts) { AccountsView(session: session) }
                .task(id: session.linkSerial) {
                    guard let section = session.linkedSection else { return }
                    let linked = Self.tab(for: section)
                    tab = visible.contains(linked) ? linked : Self.first(visible)
                    session.consumeLink()
                }
                // A tab that disappears (a feature switched off) never stays selected.
                .onChange(of: visible) { _, shown in if !shown.contains(tab) { tab = Self.first(shown) } }
                .onAppear { if !visible.contains(tab) { tab = Self.first(visible) } }
        }

        private var visible: Set<Tab> { Self.visibleTabs(for: session) }

        /// Dashboard while it has something to show; Upload only with the `upload` feature; Analytics until its API
        /// answers `feature_off`.
        static func visibleTabs(for session: StudioSession) -> Set<Tab> {
            var tabs: Set<Tab> = [.content, .editor]
            if session.showsDashboard { tabs.insert(.home) }
            if session.showsUpload { tabs.insert(.upload) }
            if session.showsAnalytics { tabs.insert(.analytics) }
            return tabs
        }

        /// Where Studio opens: the Dashboard, or Content when the Dashboard has nothing left.
        static func first(_ visible: Set<Tab>) -> Tab { visible.contains(.home) ? .home : .content }

        /// iPhone and iPad have no Recently deleted tab; it lives under Content.
        static func tab(for section: StudioLink.Section) -> Tab {
            switch section {
            case .home: .home
            case .content, .deleted: .content
            case .analytics: .analytics
            }
        }

        private func screen(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
            NavigationStack {
                content()
                    .navigationTitle(title)
                    .toolbarTitleDisplayMode(.inlineLarge)
                    .toolbar { StudioToolbar(title: title, session: session, showingAccounts: $showingAccounts) }
                    .studioNavigationBar()
                    .fanousBottomEdge(corner: UIDevice.current.userInterfaceIdiom == .pad ? 12 : 0)
            }
        }

        /// The visible tabs in their order.
        private var ordered: [Tab] { [.home, .content, .upload, .analytics, .editor].filter(visible.contains) }

        private func title(_ tab: Tab) -> String {
            switch tab {
            case .home: l10n("studio.home.title")
            case .content: l10n("studio.content.title")
            case .upload: l10n("studio.upload.title")
            case .analytics: l10n("studio.analytics.title")
            case .editor: l10n("studio.editor.title")
            }
        }

        private func icon(_ tab: Tab) -> String {
            switch tab {
            case .home: "square.grid.2x2"
            case .content: "film.stack"
            case .upload: "square.and.arrow.up"
            case .analytics: "chart.bar"
            case .editor: "scissors"
            }
        }

        private var activeUploads: Int {
            session.uploads.jobs.filter { $0.isActive && $0.accountID == session.account?.id }.count
        }

        @ViewBuilder private func page(_ tab: Tab) -> some View {
            switch tab {
            case .home: screen(title(tab)) { StudioHomeView(session: session) }
            case .content:
                screen(title(tab)) {
                    ChannelGate(session: session) { channel in ContentView(session: session, channelID: channel) }
                }
            case .upload: screen(title(tab)) { UploadView(session: session) }
            case .analytics:
                screen(title(tab)) {
                    ChannelGate(session: session) { channel in AnalyticsView(session: session, channelID: channel) }
                }
            case .editor: screen(title(tab)) { MobileEditorView() }
            }
        }

        /// iOS 18+: the adaptable tab view, so iPad gets the sidebar and iPhone the (Liquid Glass) tab bar, always at
        /// full size so every tab stays labelled in both languages. iOS 17 keeps the classic tab bar.
        @ViewBuilder private var tabs: some View {
            if #available(iOS 18, *) {
                TabView(selection: $tab) {
                    ForEach(ordered, id: \.self) { item in
                        SwiftUI.Tab(title(item), systemImage: icon(item), value: item) { page(item) }
                            .badge(item == .upload ? activeUploads : 0)
                            .accessibilityIdentifier("tab-\(item)")
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
                // iPad opens on the sidebar (the approved layout); iPhone keeps the tab bar.
                .defaultAdaptableTabBarPlacement(.sidebar)
            } else {
                TabView(selection: $tab) {
                    ForEach(ordered, id: \.self) { item in
                        page(item)
                            .tabItem { Label(title(item), systemImage: icon(item)) }
                            .badge(item == .upload ? activeUploads : 0)
                            .tag(item)
                    }
                }
            }
        }
    }
#elseif os(macOS)
    struct StudioShell: View {
        @Environment(\.l10n) private var l10n
        let session: StudioSession
        @State private var section: StudioSection? = .home
        @State private var showingAccounts = false
        @State private var columns = NavigationSplitViewVisibility.all
        @State private var encodes = EncodeQueue(
            outputDirectory: URL.moviesDirectory.appending(path: "Al Ummah Now Studio"))

        var body: some View {
            NavigationSplitView(columnVisibility: $columns) {
                List(sections) { item in
                    FanousSidebarRow(l10n(item.titleKey), icon: item.icon, selected: item == (section ?? .home)) {
                        section = item
                    }
                    .accessibilityIdentifier("section-\(item.rawValue)")
                }
                // A list that fits never scrolls, so no section slides under the title bar.
                .scrollBounceBehavior(.basedOnSize)
                // Identity at the head of the sidebar: the only identity control on the Mac.
                .safeAreaInset(edge: .top, spacing: 0) {
                    IdentityMenu(session: session, showingAccounts: $showingAccounts, style: .sidebar)
                        .padding(.horizontal, FanousScale.spacingSm)
                        .padding(.bottom, FanousScale.spacingSm)
                }
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
                .toolbar(removing: .sidebarToggle)
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
                            ChannelGate(session: session) { AnalyticsView(session: session, channelID: $0) }
                        case .encode: EncodeQueueView(queue: encodes)
                        case .editor: EditorView()
                        }
                    }
                    .toolbar {
                        FanousSidebarToggle(columns: $columns)
                        StudioToolbar(
                            title: l10n((section ?? .home).titleKey), session: session, showingAccounts: $showingAccounts)
                    }
                    .modifier(HidesWindowTitle())
                    .safeAreaInset(edge: .top, spacing: 0) { AccountStateBanner(session: session) }
                    // The web header as an opaque title bar: scrolled content never shows through the traffic lights.
                    // It resolves concrete colours here, because the window toolbar does not see the theme environment.
                    .fanousHeaderBar()
                }
            }
            .frame(minWidth: 960, minHeight: 600)
            .sheet(isPresented: $showingAccounts) { AccountsView(session: session) }
            .task(id: session.linkSerial) {
                guard let linked = session.linkedSection else { return }
                let target = Self.section(for: linked)
                section = sections.contains(target) ? target : Self.first(sections)
                session.consumeLink()
            }
            // A section that disappears (a feature switched off) never stays selected.
            .onChange(of: sections) { _, shown in
                if let section, !shown.contains(section) { self.section = Self.first(shown) }
            }
            .onAppear { if let section, !sections.contains(section) { self.section = Self.first(sections) } }
        }

        /// Upload only with the `upload` feature; Analytics until its API answers `feature_off`.
        private var sections: [StudioSection] { Self.sections(for: session) }

        /// The sidebar's sections for the session's features; the same in every language.
        static func sections(for session: StudioSession) -> [StudioSection] {
            StudioSection.allCases.filter { item in
                switch item {
                case .home: session.showsDashboard
                case .upload: session.showsUpload
                case .analytics: session.showsAnalytics
                default: true
                }
            }
        }

        /// Where Studio opens: the Dashboard, or Content when the Dashboard has nothing left.
        static func first(_ sections: [StudioSection]) -> StudioSection { sections.first ?? .content }

        static func section(for link: StudioLink.Section) -> StudioSection {
            switch link {
            case .home: .home
            case .content: .content
            case .deleted: .deleted
            case .analytics: .analytics
            }
        }
    }
#endif

#if os(macOS)
    /// The section title is drawn in the header's text colour; the system window title (white) is hidden where macOS
    /// allows it (15+).
    private struct HidesWindowTitle: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 15, *) {
                content.toolbar(removing: .title)
            } else {
                content
            }
        }
    }
#endif

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
        ToolbarItem(placement: .principal) { ChannelPicker(session: session) }
        ToolbarItem(placement: .primaryAction) { AccountButton(session: session, showing: $showingAccounts) }
    }
}

#if os(iOS)
    struct StudioShell: View {
        @Environment(\.l10n) private var l10n
        let session: StudioSession
        @State private var showingAccounts = false

        var body: some View {
            tabs.sheet(isPresented: $showingAccounts) { AccountsView(session: session) }
        }

        private var tabs: some View {
            TabView {
                NavigationStack {
                    StudioHomeView(session: session)
                        .navigationTitle(l10n("studio.home.title"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { StudioToolbar(session: session, showingAccounts: $showingAccounts) }
                }
                .tabItem { Label(l10n("studio.home.title"), systemImage: "square.grid.2x2") }
                NavigationStack {
                    UploadView(session: session)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { StudioToolbar(session: session, showingAccounts: $showingAccounts) }
                }
                .tabItem { Label(l10n("studio.upload.title"), systemImage: "square.and.arrow.up") }
                .badge(session.uploads.jobs.filter { $0.isActive && $0.accountID == session.account?.id }.count)
                NavigationStack { MobileEditorView() }
                    .tabItem { Label(l10n("studio.editor.title"), systemImage: "scissors") }
                NavigationStack {
                    Text(l10n("studio.live.unavailable"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Fanous.textSecondary)
                        .padding()
                        .accessibilityIdentifier("live-unavailable")
                        .navigationTitle(l10n("studio.live.title"))
                }
                .tabItem { Label(l10n("studio.live.title"), systemImage: "dot.radiowaves.left.and.right") }
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
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            } detail: {
                Group {
                    switch section ?? .home {
                    case .home: StudioHomeView(session: session)
                    case .upload: UploadView(session: session)
                    case .encode: EncodeQueueView(queue: encodes)
                    case .editor: EditorView()
                    }
                }
                .toolbar { StudioToolbar(session: session, showingAccounts: $showingAccounts) }
            }
            .frame(minWidth: 960, minHeight: 600)
            .sheet(isPresented: $showingAccounts) { AccountsView(session: session) }
        }
    }
#endif

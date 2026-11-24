#if os(iOS)
    import AUNCoreBridge
    import AUNDesign
    import SwiftUI

    /// iPhone and iPad shell.
    public struct ViewerRootView: View {
        @Environment(\.l10n) private var l10n
        @State private var path: [String] = []
        @State private var badge = NotificationBadge()
        @State private var features = UserFeatures.none
        @State private var isSignedIn = false
        @State private var showNotifications = false
        @State private var showEvents = false
        private let core: CoreBridge

        /// `initialVideoID` opens a watch page at launch (`-AUNOpenVideo <id>`), for UI automation.
        public init(core: CoreBridge, initialVideoID: String? = UserDefaults.standard.string(forKey: "AUNOpenVideo")) {
            self.core = core
            _path = State(initialValue: initialVideoID.map { [$0] } ?? [])
        }

        public var body: some View {
            NavigationStack(path: $path) {
                HomeView(catalog: core.catalog) { path.append($0.id) }
                    .navigationTitle(l10n("app.name"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if features.isOn(.eventCalendar) {
                                Button {
                                    showEvents = true
                                } label: {
                                    Image(systemName: "calendar")
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundStyle(Fanous.part(\.navIcon))
                                        .accessibilityLabel(l10n("events.title"))
                                }
                                .accessibilityIdentifier("events-button")
                            }
                            if isSignedIn {
                                NotificationBellButton(unseenCount: badge.unseenCount) {
                                    showNotifications = true
                                }
                            }
                            SettingsMenu()
                        }
                    }
                    .fanousNavigationBar()
                    .navigationDestination(for: String.self) { id in
                        WatchView(videoID: id, catalog: core.catalog, environment: core.environment)
                            .navigationBarTitleDisplayMode(.inline)
                            .fanousNavigationBar()
                    }
            }
            .sheet(isPresented: $showNotifications) {
                NotificationsSheetView(
                    service: core.notifications,
                    quietHoursEnabled: features.isOn(.quietHours)
                ) { badge = $0 }
            }
            .sheet(isPresented: $showEvents) {
                EventsCalendarSheetView(environment: core.environment, service: core.events)
            }
            .task {
                if let loadedFeatures = try? await core.events.viewerFeatures() {
                    features = loadedFeatures
                }
                let token = try? await core.auth.accessToken()
                isSignedIn = token != nil
                if isSignedIn, let loadedBadge = try? await core.notifications.badge() {
                    badge = loadedBadge
                }
            }
            .onOpenURL { url in
                if let id = ViewerLinks.videoID(for: url) { path = [id] }
            }
        }
    }
#endif

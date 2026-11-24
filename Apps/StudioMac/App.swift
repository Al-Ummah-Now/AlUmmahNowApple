import AUNCoreBridge
import AUNCoreKit
import AUNDesign
import AUNStudio
import AppKit
import SwiftUI
@preconcurrency import UserNotifications

final class StudioMacDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var push: AppPushController?
    @MainActor static var language: AppLanguage = .ar

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !StudioBootstrap.usesFixtures() { UNUserNotificationCenter.current().delegate = self }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        MainActor.assumeIsolated { Self.push?.didRegister(deviceToken: token, language: Self.language) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AUNLog.studio.error("Studio Mac APNs registration failed: \(error)")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

@main
struct StudioMacApp: App {
    @NSApplicationDelegateAdaptor(StudioMacDelegate.self) private var delegate
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    private let services: StudioServices
    private let preferences: UserDefaults
    private let push: AppPushController

    init() {
        AppKitLayoutDirection.match(AppSettings().language)
        let fixtures = MainActor.assumeIsolated { StudioBootstrap.usesFixtures() }
        let builtServices = StudioBootstrap.services()
        self.services = builtServices
        self.preferences = StudioBootstrap.preferences()
        let pushService: any AppPushRegistering =
            fixtures
            ? NoopAppPushService()
            : NativeAppPushService(baseURL: builtServices.environment.apiBaseURL, accounts: builtServices.accounts)
        let controller = MainActor.assumeIsolated {
            AppPushController(appRole: "studio", service: pushService, center: fixtures ? nil : .current())
        }
        self.push = controller
        MainActor.assumeIsolated { StudioMacDelegate.push = controller }
    }

    var body: some Scene {
        WindowGroup {
            StudioRootView(
                services: services,
                authenticator: StudioBootstrap.usesFixtures()
                    ? FixtureWebAuthenticator() as any WebAuthenticating : SystemWebAuthenticator(),
                preferences: preferences,
                onSignedIn: {
                    guard !StudioBootstrap.usesFixtures() else { return }
                    StudioMacDelegate.language = settings.language
                    if await push.requestAuthorization() {
                        NSApplication.shared.registerForRemoteNotifications()
                    }
                },
                onSignedOutAll: {
                    await push.unregisterOnSignOut()
                }
            )
            .fanousRoot(settings, siteTheme: siteTheme)
            .environment(settings)
            .studioWindowTitleHidden()
            .onChange(of: settings.language) { _, lang in
                StudioMacDelegate.language = lang
                Task { await push.syncRegistration(language: lang) }
            }
        }
        // Fits a 1280x800 screen (and CI's), so the bulk bar at the bottom of Content is on screen in a fresh window.
        .defaultSize(width: 1100, height: 680)
    }
}

extension View {
    /// No window title: the sidebar names the app, and an English title would sit in the Arabic chrome.
    @ViewBuilder fileprivate func studioWindowTitleHidden() -> some View {
        if #available(macOS 15, *) { toolbar(removing: .title) } else { self }
    }
}

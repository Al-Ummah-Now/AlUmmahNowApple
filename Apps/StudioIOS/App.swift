import AUNCoreBridge
import AUNCoreKit
import AUNDesign
import AUNStudio
import SwiftUI
import UIKit
@preconcurrency import UserNotifications

/// Hands iOS the completion handler when it relaunches Studio for finished background uploads,
/// and forwards APNs device tokens to `AppPushController`.
final class StudioAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var push: AppPushController?
    @MainActor static var language: AppLanguage = .ar

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if !StudioBootstrap.usesFixtures() { UNUserNotificationCenter.current().delegate = self }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        MainActor.assumeIsolated { Self.push?.didRegister(deviceToken: token, language: Self.language) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AUNLog.studio.error("Studio APNs registration failed: \(error)")
    }

    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == TUSTransfer.backgroundIdentifier else { return completionHandler() }
        nonisolated(unsafe) let completion = completionHandler
        StudioBootstrap.liveTransfer.handleBackgroundEvents { completion() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

@main
struct StudioIOSApp: App {
    @UIApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    private let services: StudioServices
    private let preferences: UserDefaults
    private let push: AppPushController

    init() {
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
        MainActor.assumeIsolated { StudioAppDelegate.push = controller }
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
                    StudioAppDelegate.language = settings.language
                    if await push.requestAuthorization() {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                },
                onSignedOutAll: {
                    await push.unregisterOnSignOut()
                }
            )
            .fanousRoot(settings, siteTheme: siteTheme)
            .environment(settings)
            .onChange(of: settings.language) { _, lang in
                StudioAppDelegate.language = lang
                Task { await push.syncRegistration(language: lang) }
            }
        }
    }
}

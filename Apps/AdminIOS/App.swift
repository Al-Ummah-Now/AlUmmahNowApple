import AUNAdmin
import AUNCoreBridge
import AUNCoreKit
import AUNDesign
import AUNStudio
import SwiftUI
import UIKit
@preconcurrency import UserNotifications

/// APNs registration, notification taps (Open, Claim) and the silent push that clears alerts.
final class AdminAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var push: AdminPush?

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if !AdminBootstrap.usesFixtures() { UNUserNotificationCenter.current().delegate = self }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        MainActor.assumeIsolated { Self.push?.didRegister(deviceToken: token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AUNLog.admin.error("APNs registration failed: \(error)")
    }

    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        nonisolated(unsafe) let info = userInfo
        await Self.push?.handleSilent(userInfo: info)
        return .noData
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        nonisolated(unsafe) let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        await Task { @MainActor in await Self.push?.handle(actionIdentifier: action, userInfo: info) }.value
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

@main
struct AdminIOSApp: App {
    @UIApplicationDelegateAdaptor(AdminAppDelegate.self) private var delegate
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    @State private var capture = CaptureMonitor(forcedCapture: UserDefaults.standard.bool(forKey: "AUNFixtureCaptured"))
    @State private var push: AdminPush
    @State private var session: AdminSession

    init() {
        let fixtures = AdminBootstrap.usesFixtures()
        let defaults = UserDefaults.standard
        let push = AdminPush(center: fixtures ? nil : .current())
        _push = State(initialValue: push)
        _session = State(
            initialValue: AdminSession(
                services: AdminBootstrap.services(),
                authenticator: fixtures ? FixtureWebAuthenticator() as any WebAuthenticating : SystemWebAuthenticator(),
                lock: fixtures
                    ? FixtureDeviceUnlock(passcode: !defaults.bool(forKey: "AUNFixtureNoPasscode")) : SystemDeviceUnlock(),
                installID: AdminBootstrap.installID(),
                network: NetworkMonitor(forcedOffline: defaults.bool(forKey: "AUNFixtureOffline"))))
        MainActor.assumeIsolated { AdminAppDelegate.push = push }
    }

    var body: some Scene {
        WindowGroup {
            AdminRootView(session: session, capture: capture, push: push)
                .fanousRoot(settings, siteTheme: siteTheme)
                .environment(settings)
                .task(id: session.phase == .ready) {
                    guard session.phase == .ready, !AdminBootstrap.usesFixtures() else { return }
                    if await push.requestAuthorization(l10n: { L10n(settings.language)($0) }) {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
        }
    }
}

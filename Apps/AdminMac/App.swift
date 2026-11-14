import AUNAdmin
import AUNCoreBridge
import AUNCoreKit
import AUNDesign
import AUNStudio
import AppKit
import SwiftUI
@preconcurrency import UserNotifications

/// APNs registration and notification taps on the Mac. Every window is kept out of screen capture.
final class AdminMacDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var push: AdminPush?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { WindowCaptureGuard.install() }
        if !AdminBootstrap.usesFixtures() { UNUserNotificationCenter.current().delegate = self }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        MainActor.assumeIsolated { Self.push?.didRegister(deviceToken: token) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AUNLog.admin.error("APNs registration failed: \(error)")
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        nonisolated(unsafe) let info = userInfo
        Task { @MainActor in await Self.push?.handleSilent(userInfo: info) }
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
struct AdminMacApp: App {
    @NSApplicationDelegateAdaptor(AdminMacDelegate.self) private var delegate
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    @State private var capture = CaptureMonitor()
    @State private var push: AdminPush
    @State private var session: AdminSession

    init() {
        MainActor.assumeIsolated { LaunchClock.appStarted() }
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
        MainActor.assumeIsolated { AdminMacDelegate.push = push }
    }

    var body: some Scene {
        WindowGroup {
            AdminRootView(session: session, capture: capture, push: push)
                .fanousRoot(settings, siteTheme: siteTheme)
                .environment(settings)
                .task(id: session.phase == .ready) {
                    guard session.phase == .ready, !AdminBootstrap.usesFixtures() else { return }
                    if await push.requestAuthorization(l10n: { L10n(settings.language)($0) }) {
                        NSApplication.shared.registerForRemoteNotifications()
                    }
                }
        }
        .defaultSize(width: 1100, height: 720)
        // One window: a second one could sit unwatched on another desktop.
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

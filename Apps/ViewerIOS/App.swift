import AUNCoreBridge
import AUNDesign
import AUNFeatures
import SwiftUI
import UIKit
@preconcurrency import UserNotifications

final class ViewerAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var push: AppPushController?
    @MainActor static var language: AppLanguage = .ar

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if !UserDefaults.standard.bool(forKey: "AUNUseFixtures") {
            UNUserNotificationCenter.current().delegate = self
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        MainActor.assumeIsolated { Self.push?.didRegister(deviceToken: token, language: Self.language) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AUNLog.network.error("Viewer APNs registration failed: \(error)")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

@main
struct ViewerIOSApp: App {
    @UIApplicationDelegateAdaptor(ViewerAppDelegate.self) private var delegate
    @State private var settings = AppSettings()
    @State private var siteTheme = SiteThemeStore.live()
    private let core: CoreBridge
    private let push: AppPushController

    init() {
        let builtCore = ViewerBootstrap.makeCore()
        self.core = builtCore
        let fixtures = UserDefaults.standard.bool(forKey: "AUNUseFixtures")
        let controller = MainActor.assumeIsolated {
            AppPushController(appRole: "viewer", service: builtCore.appPush, center: fixtures ? nil : .current())
        }
        self.push = controller
        MainActor.assumeIsolated { ViewerAppDelegate.push = controller }
    }

    var body: some Scene {
        WindowGroup {
            ViewerRootView(core: core)
                .fanousRoot(settings, siteTheme: siteTheme)
                .environment(settings)
                .task {
                    guard !UserDefaults.standard.bool(forKey: "AUNUseFixtures") else { return }
                    guard (try? await core.auth.accessToken()) != nil else { return }
                    ViewerAppDelegate.language = settings.language
                    if await push.requestAuthorization() {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
                .onChange(of: settings.language) { _, lang in
                    ViewerAppDelegate.language = lang
                    Task { await push.syncRegistration(language: lang) }
                }
        }
    }
}

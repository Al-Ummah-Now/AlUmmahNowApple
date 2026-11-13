import AUNCoreBridge
import Foundation
import Observation
@preconcurrency import UserNotifications

#if os(iOS)
    import UIKit
#endif

/// Review alerts (wiki AUN-ADMIN-NATIVE, Alerts): APNs straight to this app's bundle id, Time Sensitive, actions Open
/// and Claim only (never approve or reject from a notification), no attachments, and nothing sensitive in the text
/// ("Video held for review · NSFW · 4 min left"). A silent push with `type: review_clear` removes delivered alerts
/// when someone claims the item.
@MainActor @Observable
public final class AdminPush: NSObject {
    public static let category = "REVIEW_HELD"
    public static let openAction = "OPEN"
    public static let claimAction = "CLAIM"

    /// The review a notification asked to open; the shell selects it.
    public var pendingReviewID: String?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var session: AdminSession?
    @ObservationIgnored private let center: UNUserNotificationCenter?

    /// `center` is nil in UI tests and previews: nothing is asked or registered there.
    public init(center: UNUserNotificationCenter?) {
        self.center = center
        super.init()
    }

    /// Asks for alerts once the reviewer is signed in, and registers the action buttons.
    public func requestAuthorization(l10n: (String) -> String) async -> Bool {
        guard let center else { return false }
        let open = UNNotificationAction(identifier: Self.openAction, title: l10n("admin.push.open"), options: [.foreground])
        let claim = UNNotificationAction(
            identifier: Self.claimAction, title: l10n("admin.push.claim"), options: [.foreground, .authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [open, claim], intentIdentifiers: [], options: [])
        ])
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AUNLog.admin.error("Notification permission failed: \(error)")
            return false
        }
    }

    /// The APNs device token, as the registry wants it (hex). Never logged.
    public static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    public func didRegister(deviceToken: Data) {
        token = Self.hex(deviceToken)
        Task { await registerIfReady() }
    }

    /// Called when the session reaches `ready`.
    public func attach(_ session: AdminSession) {
        self.session = session
        Task { await registerIfReady() }
    }

    private func registerIfReady() async {
        guard let token, let session, session.phase == .ready else { return }
        #if os(macOS)
            let platform = "macos"
        #else
            let platform = ProcessInfo.processInfo.isiOSAppOnMac ? "macos" : (Self.isPad ? "ipados" : "ios")
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        do {
            try await session.services.push.register(
                installID: session.installID, token: token, platform: platform,
                locale: Locale.current.language.languageCode?.identifier ?? "en", appVersion: version)
        } catch {
            AUNLog.admin.error("Push registration failed: \(error)")
        }
    }

    #if os(iOS)
        private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    #endif

    /// A tap on an alert or one of its buttons.
    public func handle(actionIdentifier: String, userInfo: [AnyHashable: Any]) async {
        guard let reviewID = userInfo["reviewId"] as? String else { return }
        if actionIdentifier == Self.claimAction, let session, session.phase == .ready {
            try? await session.services.review.claim(reviewID)
        }
        pendingReviewID = reviewID
    }

    /// A silent push (`content-available`) that removes alerts for items someone else claimed or decided.
    public func handleSilent(userInfo: [AnyHashable: Any]) async {
        guard let center, userInfo["type"] as? String == "review_clear" else { return }
        let ids = Set(userInfo["reviewIds"] as? [String] ?? [userInfo["reviewId"] as? String].compactMap { $0 })
        guard !ids.isEmpty else { return }
        let delivered = await center.deliveredNotifications()
        let remove = delivered.filter { ids.contains($0.request.content.userInfo["reviewId"] as? String ?? "") }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: remove)
    }

    /// Sign-out: nothing left on screen for a signed-out reviewer.
    public func clearAll() {
        center?.removeAllDeliveredNotifications()
    }
}

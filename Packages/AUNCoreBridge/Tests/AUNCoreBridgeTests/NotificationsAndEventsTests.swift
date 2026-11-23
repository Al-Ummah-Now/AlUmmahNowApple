import Foundation
import Testing

@testable import AUNCoreBridge

struct NotificationsAndEventsTests {
    private let base = URL(string: "https://videos.api.qa.alummahnow.net")!

    private struct StaticAuth: AuthSessionProviding {
        func accessToken() async throws -> String? { "tok_e22" }
    }

    @Test func notificationBadgeFallsBackAndMarksSeen() async throws {
        let quietReply =
            #"{"success":true,"result":{"quietHours":{"enabled":true,"timezone":"Asia/Riyadh","#
            + #""startMinute":1320,"endMinute":360,"prayerQuietEnabled":true,"#
            + #""prayerWindows":[{"startMinute":300,"endMinute":325}]}}}"#
        let seenReply =
            #"{"success":true,"result":{"unreadCount":4,"unseenCount":0,"#
            + #""menuOpen":"read","readIds":["n1"]}}"#
        let countReply =
            #"{"success":true,"result":{"unreadCount":4,"unseenCount":2,"menuOpen":"seen"}}"#

        let session = StubURLProtocol.session { req in
            switch (req.httpMethod, req.url?.path()) {
            case ("GET", "/api/notifications/unread-count"):
                return (200, [:], Data(countReply.utf8))
            case ("POST", "/api/notifications/seen"):
                return (200, [:], Data(seenReply.utf8))
            case ("PUT", "/api/notifications/settings"):
                return (200, [:], Data(quietReply.utf8))
            default:
                return (404, [:], Data())
            }
        }
        let svc = NativeNotificationsService(baseURL: base, auth: StaticAuth(), session: session)
        let badge = try await svc.badge()
        #expect(badge.unreadCount == 4)
        #expect(badge.unseenCount == 2)
        #expect(badge.menuOpen == .seen)

        let (cleared, readIDs) = try await svc.markSeen(ids: ["n1"])
        #expect(cleared.unseenCount == 0)
        #expect(cleared.menuOpen == .read)
        #expect(readIDs == ["n1"])

        let saved = try await svc.updateQuietHours(
            NotificationQuietHours(
                enabled: true, timezone: "Asia/Riyadh", startMinute: 1320, endMinute: 360,
                prayerQuietEnabled: true,
                prayerWindows: [PrayerQuietWindow(startMinute: 300, endMinute: 325)]))
        #expect(saved.enabled)
        #expect(saved.prayerQuietEnabled)
        #expect(saved.prayerWindows.count == 1)
    }

    @Test func eventsServiceEnforcesFeatureOffAndParsesCalendar() async throws {
        let offSession = StubURLProtocol.session { _ in
            (404, [:], Data(#"{"success":false,"code":"feature_off"}"#.utf8))
        }
        let offSvc = NativeEventsService(baseURL: base, auth: GuestAuthSession(), session: offSession)
        await #expect(throws: CoreError.featureOff) {
            _ = try await offSvc.upcomingEvents(eventType: nil)
        }

        let eventsReply =
            #"{"success":true,"result":{"items":[{"streamId":"str_1","channelId":"ch_1","#
            + #""channelName":"Al-Manar","channelNameAr":"المنار","title":"Weekly Halqa","#
            + #""kind":"live","eventType":"halqa","status":"scheduled","#
            + #""scheduledStartAt":"2026-11-28T19:00:00Z","reminderCount":5,"#
            + #""viewerReminded":false,"watchPath":"/live/str_1"}]}}"#
        let onSession = StubURLProtocol.session { req in
            #expect(req.url?.path() == "/api/events")
            return (200, [:], Data(eventsReply.utf8))
        }
        let onSvc = NativeEventsService(baseURL: base, auth: GuestAuthSession(), session: onSession)
        let events = try await onSvc.upcomingEvents(eventType: "halqa")
        #expect(events.count == 1)
        #expect(events[0].displayChannelName(.ar) == "المنار")
    }

    @Test func appPushRegistersWithAppRole() async throws {
        let session = StubURLProtocol.session { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.path() == "/api/devices/inst_viewer_1")
            return (200, [:], Data(#"{"success":true,"result":{"created":true}}"#.utf8))
        }
        let push = NativeAppPushService(baseURL: base, auth: StaticAuth(), session: session)
        try await push.register(
            AppPushRegistration(
                app: "viewer", installID: "inst_viewer_1", token: String(repeating: "a", count: 64),
                platform: "ios", locale: "ar", appVersion: "1.0"))
    }
}

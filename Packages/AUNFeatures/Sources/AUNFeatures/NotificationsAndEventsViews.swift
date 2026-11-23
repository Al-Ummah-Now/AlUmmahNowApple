#if os(iOS) || os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import Observation
    import SwiftUI
    @preconcurrency import UserNotifications

    #if os(iOS)
        import UIKit
    #endif

    /// APNs registration for the Viewer and Studio apps (`app: "viewer" | "studio"`), reusing the `AdminPush` pattern.
    @MainActor @Observable
    public final class AppPushController {
        public let appRole: String
        public let installID: String
        private let service: any AppPushRegistering
        private let center: UNUserNotificationCenter?
        private var hexToken: String?

        public init(
            appRole: String = "viewer",
            installID: String = UserDefaults.standard.string(forKey: "AUNPushInstallID")
                ?? {
                    let generated = "inst_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    UserDefaults.standard.set(generated, forKey: "AUNPushInstallID")
                    return generated
                }(),
            service: any AppPushRegistering,
            center: UNUserNotificationCenter? = nil
        ) {
            self.appRole = appRole
            self.installID = installID
            self.service = service
            self.center = center
        }

        // swiftlint:disable display_format
        public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        // swiftlint:enable display_format

        public func requestAuthorization() async -> Bool {
            guard let center else { return false }
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                AUNLog.network.error("Notification authorization failed: \(error)")
                return false
            }
        }

        public func didRegister(deviceToken: Data, language: AppLanguage) {
            hexToken = Self.hex(deviceToken)
            Task { await syncRegistration(language: language) }
        }

        public func syncRegistration(language: AppLanguage) async {
            guard let hexToken else { return }
            #if os(macOS)
                let platform = "macos"
            #else
                let platform =
                    ProcessInfo.processInfo.isiOSAppOnMac
                    ? "macos" : (UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios")
            #endif
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            do {
                try await service.register(
                    AppPushRegistration(
                        app: appRole, installID: installID, token: hexToken, platform: platform,
                        locale: language.rawValue, appVersion: version))
            } catch {
                AUNLog.network.error("Device push registration failed: \(error)")
            }
        }

        public func unregisterOnSignOut() async {
            do {
                try await service.unregister(installID: installID)
            } catch {
                AUNLog.network.error("Device push unregister failed: \(error)")
            }
            center?.removeAllDeliveredNotifications()
        }
    }

    /// Toolbar ShareLink button sharing `alummahnow.link/v/<id>` (`AlUmmahNowApple#31`).
    public struct WatchShareButton: View {
        @Environment(\.l10n) private var l10n
        let environment: AppEnvironment
        let videoID: String
        var startSeconds: Int?

        public init(environment: AppEnvironment, videoID: String, startSeconds: Int? = nil) {
            self.environment = environment
            self.videoID = videoID
            self.startSeconds = startSeconds
        }

        public var body: some View {
            let url = ShortLinks.shareURL(
                environment: environment,
                target: .video(videoID),
                fallbackPath: "/video/\(videoID)",
                options: .init(startSeconds: startSeconds, languageCode: l10n.language.rawValue))
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Fanous.part(\.navIcon))
                    .accessibilityLabel(l10n("common.share"))
            }
            .accessibilityIdentifier("watch-share")
        }
    }

    /// Header notification bell showing `unseenCount` capped at `9+` / `٩+` (`Core#40`).
    public struct NotificationBellButton: View {
        @Environment(\.l10n) private var l10n
        let unseenCount: Int
        let action: () -> Void

        public init(unseenCount: Int, action: @escaping () -> Void) {
            self.unseenCount = unseenCount
            self.action = action
        }

        public var body: some View {
            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Fanous.part(\.navIcon))
                        .padding(4)
                    if let badge = DisplayFormat.badgeCap9(unseenCount, l10n.language) {
                        Text(badge)
                            .fanousFont(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(Fanous.onPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Fanous.primary))
                            .accessibilityIdentifier("notifications-badge")
                    }
                }
            }
            .accessibilityLabel(l10n("notifications.title"))
            .accessibilityIdentifier("notifications-bell")
        }
    }

    /// Notification inbox & quiet-hours sheet (`Core#40` + `E22-D6`).
    public struct NotificationsSheetView: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.dismiss) private var dismiss
        let service: any NotificationsServicing
        let onBadgeUpdate: (NotificationBadge) -> Void

        @State private var items: [NotificationEntry] = []
        @State private var quietHours = NotificationQuietHours()
        @State private var loaded = false

        private static let halfHours = stride(from: 0, to: 1440, by: 30).map { $0 }

        public init(service: any NotificationsServicing, onBadgeUpdate: @escaping (NotificationBadge) -> Void) {
            self.service = service
            self.onBadgeUpdate = onBadgeUpdate
        }

        public var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                        inboxSection
                        quietHoursSection
                    }
                    .padding(FanousScale.spacingLg)
                }
                .fanousPage()
                .navigationTitle(l10n("notifications.title"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(l10n("common.done")) { dismiss() }
                    }
                }
            }
            .task { await load() }
        }

        private var inboxSection: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                if !items.isEmpty {
                    HStack {
                        Spacer()
                        Button(l10n("notifications.markAllRead")) {
                            Task {
                                if let badge = try? await service.markAllRead() {
                                    onBadgeUpdate(badge)
                                    let now = Date.now
                                    items = items.map {
                                        var copy = $0
                                        copy.readAt = copy.readAt ?? now
                                        return copy
                                    }
                                }
                            }
                        }
                        .fanousFont(.caption)
                        .foregroundStyle(Fanous.link)
                        .accessibilityIdentifier("notifications-mark-all-read")
                    }
                }

                if items.isEmpty && loaded {
                    Text(l10n("notifications.empty"))
                        .fanousFont(.body)
                        .foregroundStyle(Fanous.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(FanousScale.spacingLg)
                        .fanousMaterial(.card) { .rounded($0.lg) }
                } else {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: FanousScale.spacingMd) {
                            Circle()
                                .fill(Fanous.primary)
                                .opacity(item.isRead ? 0 : 1)
                                .frame(width: 8, height: 8)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .fanousFont(.body)
                                    .fontWeight(item.isRead ? .regular : .semibold)
                                    .foregroundStyle(Fanous.textPrimary)
                                Text(DisplayFormat.shortDay(item.createdAt, l10n.language))
                                    .fanousFont(.caption)
                                    .foregroundStyle(Fanous.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(FanousScale.spacingMd)
                        .fanousMaterial(.card) { .rounded($0.md) }
                    }
                }
            }
        }

        private var quietHoursSection: some View {
            VStack(alignment: .leading, spacing: FanousScale.spacingMd) {
                Text(l10n("notifications.quiet.title"))
                    .fanousFont(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(Fanous.textPrimary)

                Toggle(
                    l10n("notifications.quiet.daily"),
                    isOn: Binding(
                        get: { quietHours.enabled },
                        set: { value in
                            quietHours.enabled = value
                            saveQuietHours()
                        })
                )
                .foregroundStyle(Fanous.textPrimary)
                .accessibilityIdentifier("quiet-daily-toggle")

                HStack(spacing: FanousScale.spacingMd) {
                    Picker(
                        l10n("notifications.quiet.start"),
                        selection: Binding(
                            get: { quietHours.startMinute },
                            set: { value in
                                quietHours.startMinute = value
                                saveQuietHours()
                            })
                    ) {
                        ForEach(Self.halfHours, id: \.self) { minute in
                            Text(DisplayFormat.minuteOfDay(minute, l10n.language)).tag(minute)
                        }
                    }
                    Picker(
                        l10n("notifications.quiet.end"),
                        selection: Binding(
                            get: { quietHours.endMinute },
                            set: { value in
                                quietHours.endMinute = value
                                saveQuietHours()
                            })
                    ) {
                        ForEach(Self.halfHours, id: \.self) { minute in
                            Text(DisplayFormat.minuteOfDay(minute, l10n.language)).tag(minute)
                        }
                    }
                }

                Toggle(
                    l10n("notifications.quiet.prayer"),
                    isOn: Binding(
                        get: { quietHours.prayerQuietEnabled },
                        set: { value in
                            quietHours.prayerQuietEnabled = value
                            saveQuietHours()
                        })
                )
                .foregroundStyle(Fanous.textPrimary)
                .accessibilityIdentifier("quiet-prayer-toggle")

                Text(l10n("notifications.quiet.note"))
                    .fanousFont(.caption)
                    .foregroundStyle(Fanous.textSecondary)
            }
            .padding(FanousScale.spacingLg)
            .fanousMaterial(.card) { .rounded($0.lg) }
            .accessibilityIdentifier("notifications-quiet-section")
        }

        private func load() async {
            if let (list, _) = try? await service.list(limit: 20) {
                items = list
                if let (cleared, readIDs) = try? await service.markSeen(ids: list.map(\.id)) {
                    onBadgeUpdate(cleared)
                    if !readIDs.isEmpty {
                        let readSet = Set(readIDs)
                        let now = Date.now
                        items = items.map {
                            guard readSet.contains($0.id) else { return $0 }
                            var copy = $0
                            copy.readAt = copy.readAt ?? now
                            return copy
                        }
                    }
                }
            }
            if let fetchedQuiet = try? await service.quietHours() {
                quietHours = fetchedQuiet
            }
            loaded = true
        }

        private func saveQuietHours() {
            let snapshot = quietHours
            Task {
                if let saved = try? await service.updateQuietHours(snapshot) {
                    quietHours = saved
                }
            }
        }
    }

    /// Feature-gated online Event Calendar sheet (`E22-D7`: online events only, hidden when `eventCalendar` is off).
    public struct EventsCalendarSheetView: View {
        @Environment(\.l10n) private var l10n
        @Environment(\.dismiss) private var dismiss
        let environment: AppEnvironment
        let service: any EventsServicing

        @State private var events: [CalendarEvent] = []
        @State private var selectedType: String = "all"
        @State private var loaded = false

        private static let types = ["all", "jumuah", "taraweeh", "conference", "halqa"]

        public init(environment: AppEnvironment, service: any EventsServicing) {
            self.environment = environment
            self.service = service
        }

        public var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                        Picker(l10n("events.title"), selection: $selectedType) {
                            ForEach(Self.types, id: \.self) { type in
                                Text(l10n("events.filter.\(type)")).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedType) { _, next in
                            Task { await load(type: next) }
                        }

                        if events.isEmpty && loaded {
                            Text(l10n("events.empty"))
                                .fanousFont(.body)
                                .foregroundStyle(Fanous.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(FanousScale.spacingLg)
                                .fanousMaterial(.card) { .rounded($0.lg) }
                        } else {
                            ForEach(events) { event in
                                eventCard(event)
                            }
                        }
                    }
                    .padding(FanousScale.spacingLg)
                }
                .fanousPage()
                .navigationTitle(l10n("events.title"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(l10n("common.done")) { dismiss() }
                    }
                }
            }
            .task { await load(type: selectedType) }
        }

        private func eventCard(_ event: CalendarEvent) -> some View {
            let shareURL = ShortLinks.shareURL(
                environment: environment, target: .live(event.streamId),
                fallbackPath: event.watchPath, options: .init(languageCode: l10n.language.rawValue))
            return VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(event.status == "live" ? l10n("events.liveNow") : l10n("events.upcoming"))
                        .fanousFont(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(Fanous.link)
                    if event.kind == "premiere" {
                        Text(l10n("events.premiere"))
                            .fanousFont(.caption)
                            .foregroundStyle(Fanous.textSecondary)
                    }
                    Spacer(minLength: 0)
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Fanous.link)
                            .accessibilityLabel(l10n("common.share"))
                    }
                }
                Text(event.title)
                    .fanousFont(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Fanous.textPrimary)
                Text(eventMetadata(event))
                    .fanousFont(.caption)
                    .foregroundStyle(Fanous.textSecondary)
            }
            .padding(FanousScale.spacingLg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fanousMaterial(.card) { .rounded($0.lg) }
            .accessibilityIdentifier("event-card-\(event.streamId)")
        }

        private func eventMetadata(_ event: CalendarEvent) -> String {
            let dateText = (event.scheduledStartAt ?? event.startedAt)
                .flatMap { try? Date($0, strategy: .iso8601) }
                .map { DisplayFormat.dateTime($0, l10n.language) }
            return DisplayFormat.meta([event.displayChannelName(l10n.language), dateText], l10n.language)
        }

        private func load(type: String) async {
            let filter = type == "all" ? nil : type
            events = (try? await service.upcomingEvents(eventType: filter)) ?? []
            loaded = true
        }
    }
#endif

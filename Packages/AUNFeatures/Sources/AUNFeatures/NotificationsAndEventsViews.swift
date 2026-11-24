#if os(iOS) || os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import SwiftUI

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
        let quietHoursEnabled: Bool
        let localPrayerWindows: [PrayerQuietWindow]
        let onBadgeUpdate: (NotificationBadge) -> Void

        @State private var items: [NotificationEntry] = []
        @State private var quietHours = NotificationQuietHours()
        @State private var loaded = false
        @State private var loadFailed = false
        @State private var quietHoursLoaded = false

        private static let halfHours = stride(from: 0, to: 1440, by: 30).map { $0 }

        public init(
            service: any NotificationsServicing,
            quietHoursEnabled: Bool = false,
            localPrayerWindows: [PrayerQuietWindow] = [],
            onBadgeUpdate: @escaping (NotificationBadge) -> Void
        ) {
            self.service = service
            self.quietHoursEnabled = quietHoursEnabled
            self.localPrayerWindows = localPrayerWindows
            self.onBadgeUpdate = onBadgeUpdate
        }

        public static func localizedTitle(for item: NotificationEntry, l10n: L10n) -> String {
            if let formatted = formattedMessage(for: item, l10n: l10n) {
                return formatted
            }
            let titleKey = "notifications.item.\(item.notificationKey)"
            let resolved = l10n(titleKey)
            if resolved != titleKey { return resolved }
            return item.title.isEmpty ? l10n("notifications.item.default") : item.title
        }

        private static func formattedMessage(for item: NotificationEntry, l10n: L10n) -> String? {
            func param(_ key: String) -> String {
                (item.params[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let isAr = l10n.language == .ar
            func localizedParam(_ base: String) -> String {
                if isAr {
                    let arVal = param("\(base)_ar")
                    if !arVal.isEmpty { return arVal }
                }
                return param(base)
            }
            func iso(_ text: String) -> String {
                text.isEmpty ? "" : DisplayFormat.isolate(text)
            }
            let video = iso(param("videoTitle"))
            let rawStream = param("streamTitle")
            let stream = rawStream.isEmpty ? video : iso(rawStream)
            let rawChannel = localizedParam("channelName")
            let channel = iso(rawChannel.isEmpty ? localizedParam("channel") : rawChannel)
            let tierRaw = isAr ? param("tier_ar") : param("tier_en")
            let tier = iso(tierRaw.isEmpty ? param("tier") : tierRaw)
            let inviter = iso(localizedParam("inviter"))
            let member = iso(localizedParam("member"))
            let actor = iso(localizedParam("actorName"))

            switch item.notificationKey {
            case "newVideo" where !channel.isEmpty && !video.isEmpty:
                return l10n("notifications.item.newVideo.msg", channel, video)
            case "liveStarted" where !channel.isEmpty && !stream.isEmpty:
                return l10n("notifications.item.liveStarted.msg", channel, stream)
            case "commentReply" where !actor.isEmpty:
                return l10n("notifications.item.commentReply.msg", actor)
            case "newComment" where !video.isEmpty:
                return l10n("notifications.item.newComment.msg", video)
            case "newSubscriber" where !channel.isEmpty:
                return l10n("notifications.item.newSubscriber.msg", channel)
            case "uploadReady" where !video.isEmpty:
                return l10n("notifications.item.uploadReady.msg", video)
            case "uploadFailed" where !video.isEmpty:
                return l10n("notifications.item.uploadFailed.msg", video)
            case "reviewApproved" where !video.isEmpty:
                return l10n("notifications.item.reviewApproved.msg", video)
            case "reviewRejected" where !video.isEmpty:
                return l10n("notifications.item.reviewRejected.msg", video)
            case "reviewNeeded" where !video.isEmpty:
                return l10n("notifications.item.reviewNeeded.msg", video)
            case "channelInviteReceived" where !inviter.isEmpty && !channel.isEmpty:
                return l10n("notifications.item.channelInviteReceived.msg", inviter, channel)
            case "channelInviteAccepted" where !member.isEmpty && !channel.isEmpty:
                return l10n("notifications.item.channelInviteAccepted.msg", member, channel)
            case "tierRequestApproved" where !tier.isEmpty:
                return l10n("notifications.item.tierRequestApproved.msg", tier)
            case "tierRequestDeclined" where !tier.isEmpty:
                return l10n("notifications.item.tierRequestDeclined.msg", tier)
            case "tierRequestReceived" where !tier.isEmpty:
                return l10n("notifications.item.tierRequestReceived.msg", tier)
            default:
                return nil
            }
        }

        public var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                        inboxSection
                        if quietHoursEnabled && quietHoursLoaded {
                            quietHoursSection
                        }
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

                if !loaded {
                    ThemeLoader()
                        .frame(maxWidth: .infinity)
                        .padding(FanousScale.spacingLg)
                } else if loadFailed {
                    VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                        Text(l10n("common.error.load"))
                            .fanousFont(.body)
                            .foregroundStyle(Fanous.errorText)
                        Button(l10n("common.retry")) {
                            Task { await load() }
                        }
                        .fanousFont(.label)
                        .foregroundStyle(Fanous.link)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FanousScale.spacingLg)
                    .fanousMaterial(.card) { .rounded($0.lg) }
                } else if items.isEmpty {
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
                                Text(Self.localizedTitle(for: item, l10n: l10n))
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
                            var next = quietHours
                            next.enabled = value
                            if next.timezone.isEmpty || next.timezone == "UTC" {
                                next.timezone = TimeZone.current.identifier
                            }
                            saveQuietHours(next)
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
                                var next = quietHours
                                next.startMinute = value
                                saveQuietHours(next)
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
                                var next = quietHours
                                next.endMinute = value
                                saveQuietHours(next)
                            })
                    ) {
                        ForEach(Self.halfHours, id: \.self) { minute in
                            Text(DisplayFormat.minuteOfDay(minute, l10n.language)).tag(minute)
                        }
                    }
                }

                // Hidden until Epic 21.1 supplies non-empty locally computed prayer windows on this device.
                if !localPrayerWindows.isEmpty {
                    Toggle(
                        l10n("notifications.quiet.prayer"),
                        isOn: Binding(
                            get: { quietHours.prayerQuietEnabled },
                            set: { value in
                                var next = quietHours
                                next.prayerQuietEnabled = value
                                next.prayerWindows = Array(localPrayerWindows.prefix(5))
                                saveQuietHours(next)
                            })
                    )
                    .foregroundStyle(Fanous.textPrimary)
                    .accessibilityIdentifier("quiet-prayer-toggle")
                }

                Text(l10n("notifications.quiet.note"))
                    .fanousFont(.caption)
                    .foregroundStyle(Fanous.textSecondary)
            }
            .padding(FanousScale.spacingLg)
            .fanousMaterial(.card) { .rounded($0.lg) }
            .accessibilityIdentifier("notifications-quiet-section")
        }

        private func load() async {
            loaded = false
            loadFailed = false
            do {
                let (list, _) = try await service.list(limit: 20)
                items = list
                if !list.isEmpty, let (cleared, readIDs) = try? await service.markSeen(ids: list.map(\.id)) {
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
            } catch {
                loadFailed = true
            }
            if quietHoursEnabled, let fetchedQuiet = try? await service.quietHours() {
                var resolved = fetchedQuiet
                if resolved.timezone.isEmpty || resolved.timezone == "UTC" {
                    resolved.timezone = TimeZone.current.identifier
                }
                quietHours = resolved
                quietHoursLoaded = true
            }
            loaded = true
        }

        private func saveQuietHours(_ next: NotificationQuietHours) {
            let previous = quietHours
            quietHours = next
            Task {
                do {
                    quietHours = try await service.updateQuietHours(next)
                } catch {
                    quietHours = previous
                }
            }
        }
    }

    /// Feature-gated online Event Calendar sheet (`E22-D7`: online events only, hidden when `eventCalendar` is off).
    public struct EventsCalendarSheetView: View {
        private struct FilterOption: Equatable {
            var id: String
            var kind: String?
            var eventType: String?
        }

        @Environment(\.l10n) private var l10n
        @Environment(\.dismiss) private var dismiss
        let environment: AppEnvironment
        let service: any EventsServicing

        @State private var events: [CalendarEvent] = []
        @State private var selectedFilterID: String = "all"
        @State private var loaded = false
        @State private var loadFailed = false

        private static let filters: [FilterOption] = [
            FilterOption(id: "all", kind: nil, eventType: nil),
            FilterOption(id: "live", kind: "live", eventType: nil),
            FilterOption(id: "premiere", kind: "premiere", eventType: nil),
            FilterOption(id: "jumuah", kind: nil, eventType: "jumuah"),
            FilterOption(id: "taraweeh", kind: nil, eventType: "taraweeh"),
            FilterOption(id: "conference", kind: nil, eventType: "conference"),
            FilterOption(id: "halqa", kind: nil, eventType: "halqa"),
        ]

        public init(environment: AppEnvironment, service: any EventsServicing) {
            self.environment = environment
            self.service = service
        }

        public var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: FanousScale.spacingSm) {
                                ForEach(Self.filters, id: \.id) { option in
                                    let isSelected = selectedFilterID == option.id
                                    Button {
                                        selectedFilterID = option.id
                                        Task { await load(option: option) }
                                    } label: {
                                        Text(l10n("events.filter.\(option.id)"))
                                            .fanousFont(.caption)
                                            .fontWeight(isSelected ? .semibold : .regular)
                                            .foregroundStyle(isSelected ? Fanous.onPrimary : Fanous.textPrimary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(
                                                Capsule().fill(
                                                    isSelected
                                                        ? AnyShapeStyle(Fanous.primary)
                                                        : AnyShapeStyle(Color.secondary.opacity(0.15)))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !loaded {
                            ThemeLoader()
                                .frame(maxWidth: .infinity)
                                .padding(FanousScale.spacingLg)
                        } else if loadFailed {
                            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                                Text(l10n("common.error.load"))
                                    .fanousFont(.body)
                                    .foregroundStyle(Fanous.errorText)
                                Button(l10n("common.retry")) {
                                    let current = Self.filters.first { $0.id == selectedFilterID } ?? Self.filters[0]
                                    Task { await load(option: current) }
                                }
                                .fanousFont(.label)
                                .foregroundStyle(Fanous.link)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(FanousScale.spacingLg)
                            .fanousMaterial(.card) { .rounded($0.lg) }
                        } else if events.isEmpty {
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
            .task { await load(option: Self.filters[0]) }
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

        private func load(option: FilterOption) async {
            loaded = false
            loadFailed = false
            do {
                events = try await service.upcomingEvents(kind: option.kind, eventType: option.eventType)
            } catch {
                loadFailed = true
            }
            loaded = true
        }
    }
#endif

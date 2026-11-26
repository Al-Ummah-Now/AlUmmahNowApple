import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Studio's Videos: tabs by status, search with live suggestions, edit one video, act on many.
struct ContentView: View {
    @Environment(\.l10n) private var l10n
    let session: StudioSession
    @State private var model: ContentModel
    @State private var editing: StudioVideo?
    @State private var sheet: BulkSheet?
    @State private var confirmingDelete: [String]?
    #if os(iOS)
        @State private var editMode: EditMode = .inactive
    #endif

    enum BulkSheet: String, Identifiable {
        case edit, schedule, playlist
        var id: String { rawValue }
    }

    init(session: StudioSession, channelID: String) {
        self.session = session
        _model = State(initialValue: Self.model(for: session, channelID: channelID))
    }

    /// The model's errors belong to the account it was made for, also when another one is active by then.
    static func model(for session: StudioSession, channelID: String) -> ContentModel {
        let ownerAccountID = session.account?.id
        let model = ContentModel(channelID: channelID, services: session.services)
        model.onError = { [weak session] in session?.note($0, forAccount: ownerAccountID) }
        model.showsStats = { [weak session] in session?.showsAnalytics ?? false }
        model.onStatsOff = { [weak session] in session?.featureOff(.analytics) }
        model.showsBulkSchedule = { [weak session] in session?.shows(.bulkSchedule) ?? false }
        return model
    }

    var body: some View {
        VStack(spacing: 0) {
            statusPicker
            list
            if !model.selection.isEmpty { bulkBar }
        }
        .fanousPage()
        .navigationTitle(l10n("studio.content.title"))
        .searchable(
            text: $model.searchText, placement: Self.searchPlacement, prompt: Text(l10n("studio.content.search"))
        )
        .searchSuggestions {
            ForEach(model.suggestions) { suggestion in
                suggestionRow(suggestion)
            }
        }
        .onSubmit(of: .search) { model.reload() }
        .task { if model.state == .idle { model.reload() } }
        // Back from Recently deleted (or another tab), the list may have changed.
        .onAppear { if model.state != .idle { model.reload() } }
        .refreshable { model.reload() }
        .sheet(item: $editing) { video in
            VideoEditView(model: model, video: video) { ids in confirmingDelete = ids }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .edit: BulkEditView(model: model)
            case .schedule: BulkScheduleView(model: model)
            case .playlist: PlaylistPickView(model: model)
            }
        }
        .sheet(
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })
        ) {
            let ids = confirmingDelete ?? []
            ConfirmSheet(
                title: l10n("studio.content.deleteTitle", DisplayFormat.number(ids.count, l10n.language)),
                message: l10n("studio.content.deleteMessage", DisplayFormat.number(DeletedVideo.restoreDays, l10n.language)),
                actionTitle: l10n("studio.content.delete")
            ) {
                editing = nil
                Task { await model.delete(ids) }
            }
        }
        .overlay(alignment: .bottom) { MessageBanner(message: $model.message) }
    }

    /// On a phone the search field stays in view, rather than hiding until the list is pulled down.
    #if os(iOS)
        static let searchPlacement = SearchFieldPlacement.navigationBarDrawer(displayMode: .always)
    #else
        static let searchPlacement = SearchFieldPlacement.automatic
    #endif

    /// iOS opens the editor with a tap, or selects while selecting. The Mac leaves the click to the List, so a click
    /// selects, and opens the editor on a double-click (`primaryAction`); a tap gesture on the row would eat the click.
    private var opensOnTap: Bool {
        #if os(iOS)
            !editMode.isEditing
        #else
            false
        #endif
    }

    /// Status tabs, then sort and select, in the screen rather than the toolbar: the toolbar keeps the channel picker
    /// and the account button visible on a phone.
    private var statusPicker: some View {
        VStack(spacing: FanousScale.spacingXs) {
            // Status chips: the selected one in the gold primary material, the rest outlined (a system segmented
            // control can't take the gradient).
            // A row wider than the screen fades at both edges (so a cut chip reads as "more"), and the chosen chip
            // scrolls fully into view.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FanousScale.spacingSm) {
                        ForEach(StudioStatus.allCases, id: \.self) { status in
                            StatusChip(title: label(for: status), selected: model.status == status) { model.status = status }
                                .id(status)
                                .accessibilityIdentifier("status-\(status.rawValue)")
                        }
                    }
                    .padding(.horizontal, FanousScale.spacingLg)
                    .padding(.vertical, 2)
                }
                .mask(EdgeFade(width: FanousScale.spacingLg))
                .onChange(of: model.status) { _, status in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(status, anchor: .center) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(l10n("studio.content.status"))
            .accessibilityIdentifier("content-status")
            HStack {
                Menu {
                    Picker(l10n("studio.content.sort"), selection: $model.sort) {
                        ForEach(ContentSort.allCases, id: \.self) { Text(l10n("studio.sort.\($0.rawValue)")).tag($0) }
                    }
                } label: {
                    Label(l10n("studio.sort.\(model.sort.rawValue)"), systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel(l10n("studio.content.sort"))
                .accessibilityValue(l10n("studio.sort.\(model.sort.rawValue)"))
                .accessibilityIdentifier("content-sort")
                Spacer()
                #if os(iOS)
                    // The Mac has Recently deleted in its sidebar.
                    NavigationLink {
                        RecentlyDeletedView(services: model.services, channelID: model.channelID).studioNavigationBar()
                    } label: {
                        Label(l10n("studio.deleted.title"), systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(l10n("studio.deleted.title"))
                    .accessibilityIdentifier("open-deleted")
                    .padding(.trailing, FanousScale.spacingMd)
                    Button(l10n(editMode.isEditing ? "common.done" : "studio.content.select")) {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                            if !editMode.isEditing { model.selection = [] }
                        }
                    }
                    .accessibilityIdentifier("content-select")
                #endif
            }
            .fanousFont(.label)
            .padding(.horizontal, FanousScale.spacingLg)
        }
        .padding(.vertical, FanousScale.spacingSm)
    }

    private func label(for status: StudioStatus) -> String {
        let name = l10n("studio.tab.\(status.rawValue)")
        guard let count = model.counts[status] else { return name }
        return "\(name) \(DisplayFormat.number(count, l10n.language))"
    }

    @ViewBuilder private var list: some View {
        switch model.state {
        case .failed where model.items.isEmpty:
            ErrorStateView { model.reload() }
        case .loading where model.items.isEmpty, .idle:
            ThemeLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if model.items.isEmpty {
                EmptyStateView(
                    title: l10n(model.searchText.isEmpty ? "studio.content.empty" : "studio.content.noMatch"),
                    message: l10n("studio.content.emptyMessage"))
            } else {
                List(selection: $model.selection) {
                    ForEach(model.items) { video in
                        VideoRowWithAction {
                            VideoRow(video: video)
                        } action: {
                            if opensOnTap {
                                // The card's action at its trailing end (owner rule); a tap anywhere also opens it.
                                Button(l10n("studio.content.edit")) { editing = video }
                                    .buttonStyle(FanousButtonStyle(.secondary))
                                    .accessibilityIdentifier("edit-\(video.id)")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 1, perform: { editing = video }, when: opensOnTap)
                        .swipeActions(edge: .trailing) {
                            Button(l10n("studio.content.delete"), role: .destructive) { confirmingDelete = [video.id] }
                        }
                        #if os(iOS)
                            .contextMenu {
                                Button(l10n("studio.content.edit")) { editing = video }
                                Button(l10n("studio.content.delete"), role: .destructive) { confirmingDelete = [video.id] }
                            }
                        #endif
                        // Each video on its own card: the card material, spaced, no separators.
                        .listRowBackground(
                            FanousSurfaceKind(kind: .card, shape: .rounded(16))
                                .padding(.vertical, FanousScale.spacingXs)
                                .padding(.horizontal, FanousScale.spacingSm)
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(
                            EdgeInsets(
                                top: 10, leading: FanousScale.spacingLg + 4, bottom: 10, trailing: FanousScale.spacingLg + 4)
                        )
                        .tag(video.id)
                        .task { if video.id == model.items.last?.id { await model.loadMore() } }
                    }
                }
                .scrollContentBackground(.hidden)
                #if os(iOS)
                    .environment(\.editMode, $editMode)
                #else
                    .contextMenu(forSelectionType: String.self) { ids in
                        if ids.count == 1, let video = model.items.first(where: { ids.contains($0.id) }) {
                            Button(l10n("studio.content.edit")) { editing = video }
                        }
                        if !ids.isEmpty {
                            Button(l10n("studio.content.delete"), role: .destructive) { confirmingDelete = Array(ids) }
                        }
                    } primaryAction: { ids in
                        if ids.count == 1, let video = model.items.first(where: { ids.contains($0.id) }) { editing = video }
                    }
                #endif
                .accessibilityIdentifier("content-list")
            }
        }
    }

    private func suggestionRow(_ suggestion: StudioSuggestion) -> some View {
        Button {
            if let id = suggestion.itemID, let video = model.items.first(where: { $0.id == id }) {
                editing = video
            } else {
                model.searchText = suggestion.text
                model.reload()
            }
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(suggestion.text)
                    if let subtitle = suggestion.subtitle { Text(subtitle).font(.caption).foregroundStyle(Fanous.textSecondary) }
                }
            } icon: {
                Image(systemName: suggestion.kind == .video ? "film" : "magnifyingglass")
            }
        }
        .accessibilityIdentifier("suggestion-\(suggestion.id)")
    }

    private var bulkBar: some View {
        let count = DisplayFormat.number(model.selection.count, l10n.language)
        return ViewThatFits {
            HStack(spacing: FanousScale.spacingMd) { bulkButtons(count) }
            ScrollView(.horizontal) { HStack(spacing: FanousScale.spacingMd) { bulkButtons(count) } }
        }
        .padding(FanousScale.spacingMd)
        .frame(maxWidth: .infinity)
        .fanousMaterial(.raised) { .rounded($0.xl) }
        .padding(.horizontal, FanousScale.spacingSm)
        .padding(.bottom, FanousScale.spacingXs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bulk-bar")
    }

    @ViewBuilder private func bulkButtons(_ count: String) -> some View {
        Text(l10n("studio.content.selected", count)).fanousFont(.label).foregroundStyle(Fanous.textPrimary)
        Spacer(minLength: 0)
        if model.showsBulkSchedule() {
            Button(l10n("studio.content.bulkSchedule")) { sheet = .schedule }
                .buttonStyle(FanousButtonStyle(.secondary)).accessibilityIdentifier("bulk-schedule")
        }
        Button(l10n("studio.content.bulkPlaylist")) { sheet = .playlist }
            .buttonStyle(FanousButtonStyle(.secondary)).accessibilityIdentifier("bulk-playlist")
        Button(l10n("studio.content.delete"), role: .destructive) { confirmingDelete = Array(model.selection) }
            .buttonStyle(FanousButtonStyle(.ghost)).foregroundStyle(Fanous.errorText).accessibilityIdentifier("bulk-delete")
        // Gold only for the primary action, at the trailing end.
        Button(l10n("studio.content.bulkEdit")) { sheet = .edit }
            .buttonStyle(FanousButtonStyle(.primary)).accessibilityIdentifier("bulk-edit")
    }
}

/// A video row and its action: side by side, or at accessibility text sizes the action under the row (at its trailing
/// end), so the title keeps the row's width.
struct VideoRowWithAction<Row: View, Action: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let row: () -> Row
    @ViewBuilder let action: () -> Action

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                row()
                HStack {
                    Spacer(minLength: 0)
                    action()
                }
            }
        } else {
            HStack(spacing: FanousScale.spacingSm) {
                row()
                action()
            }
        }
    }
}

/// One video in the list: thumbnail, title, status and numbers. At accessibility text sizes they stack, so the text
/// gets the whole width.
struct VideoRow: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let video: StudioVideo
    /// Leads the details with the video's status (Processing, Failed…), as the Dashboard lists mixed statuses.
    var showsStatus = false

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                    thumbnail(width: 160)
                    titleAndDetails.fixedSize(horizontal: false, vertical: true)
                    date
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: FanousScale.spacingMd) {
                    thumbnail(width: 96)
                    titleAndDetails
                        // Its own height, not the thumbnail's: the title and details wrap instead of truncating to one line.
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: FanousScale.spacingSm)
                    date
                        .lineLimit(1).fixedSize()
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .padding(.vertical, FanousScale.spacingXs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("video-\(video.id)")
    }

    private func thumbnail(width: CGFloat) -> some View {
        ThumbnailImage(url: video.thumbnailURL)
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private var titleAndDetails: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            // Three lines before truncating: long Arabic titles otherwise lose the part that tells them apart ("…الجزء").
            Text(video.displayTitle(l10n.language)).fanousFont(.body).foregroundStyle(Fanous.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 6 : 3)
            // Up to two lines: narrow cards (the Mac Dashboard's half-width column) wrap rather than cut the
            // status and views. The date has its own column, so it never wraps ("Nov / 6, 2026").
            Text(details).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
        }
    }

    @ViewBuilder private var date: some View {
        if let date = video.dateCreated {
            Text(DisplayFormat.shortDay(date, l10n.language)).fanousFont(.caption).foregroundStyle(Fanous.textMuted)
        }
    }

    private var details: String {
        var parts = [l10n(video.isPublic ? "visibility.public" : "visibility.private")]
        if showsStatus, let status = video.studioStatus { parts.insert(l10n("studio.tab.\(status.rawValue)"), at: 0) }
        if let date = video.scheduledPublishDate, video.studioStatus == .scheduled {
            parts.append(l10n("studio.content.publishes", DisplayFormat.shortDay(date, l10n.language)))
        } else {
            parts.append(DisplayFormat.views(video.views, l10n))
        }
        return DisplayFormat.meta(parts, l10n.language)
    }
}

/// A short-lived message at the bottom of a screen.
struct MessageBanner: View {
    @Environment(\.l10n) private var l10n
    @Binding var message: (key: String, values: [String])?

    var body: some View {
        if let message {
            Text(text(message))
                .fanousFont(.label)
                .foregroundStyle(Fanous.textPrimary)
                .padding(FanousScale.spacingMd)
                .fanousMaterial(.raised) { .rounded($0.md) }
                .padding(FanousScale.spacingLg)
                .accessibilityIdentifier("message")
                .foregroundStyle(isError(message.key) ? Fanous.errorText : Fanous.textPrimary)
                .accessibilityHint(l10n("common.dismiss"))
                // Success messages leave after 5 s; errors stay until dismissed, so they are never missed. On fixtures
                // (UI tests) success messages stay too: a slow CI simulator can take longer than 5 s to look.
                .task(id: message.key + message.values.joined()) {
                    guard !isError(message.key), !Self.holdsMessages else { return }
                    try? await Task.sleep(for: .seconds(5))
                    self.message = nil
                }
                .onTapGesture { self.message = nil }
        }
    }

    private static let holdsMessages = UserDefaults.standard.bool(forKey: "AUNUseFixtures")

    private func isError(_ key: String) -> Bool {
        key.hasPrefix("studio.error.") || key.hasPrefix("studio.refusal.") || key.hasPrefix("studio.account.")
            || key == "studio.upload.error.limit"
    }

    private func text(_ message: (key: String, values: [String])) -> String {
        let numbers = message.values.map { Int($0).map { DisplayFormat.number($0, l10n.language) } ?? $0 }
        switch numbers.count {
        case 0: return l10n(message.key)
        case 1: return l10n(message.key, numbers[0])
        default: return l10n(message.key, numbers[0], numbers[1])
        }
    }
}

extension View {
    /// A tap action only while `active`, so a List's own selection gets the tap otherwise.
    @ViewBuilder
    func onTapGesture(count: Int, perform action: @escaping () -> Void, when active: Bool) -> some View {
        if active { onTapGesture(count: count, perform: action) } else { self }
    }
}

/// A status filter chip: the selected one in the gold primary material, the others outlined.
struct StatusChip: View {
    @Environment(\.fanous) private var theme
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .fanousFont(.label)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? Color(theme.parts.buttonPrimaryText) : Color(theme.colors.textSecondary))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background {
                    if selected {
                        FanousSurfaceKind(kind: .primary, shape: .capsule)
                    } else {
                        Capsule().strokeBorder(Color(theme.colors.outline), lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A horizontal mask that fades both edges of a scrolling row over `width` points.
private struct EdgeFade: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: width)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: width)
        }
    }
}

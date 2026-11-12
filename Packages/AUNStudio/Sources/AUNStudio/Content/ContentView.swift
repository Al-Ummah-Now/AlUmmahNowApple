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
        _model = State(initialValue: ContentModel(channelID: channelID, services: session.services))
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
                title: l10n("studio.content.deleteTitle", ids.count.formatted(.number.locale(l10n.language.locale))),
                message: l10n("studio.content.deleteMessage"), actionTitle: l10n("studio.content.delete")
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
            ScrollView(.horizontal, showsIndicators: false) {
                Picker(l10n("studio.content.status"), selection: $model.status) {
                    ForEach(StudioStatus.allCases, id: \.self) { status in
                        Text(label(for: status)).tag(status)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .padding(.horizontal, FanousScale.spacingLg)
                .accessibilityIdentifier("content-status")
            }
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
        return "\(name) \(count.formatted(.number.locale(l10n.language.locale)))"
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
                        VideoRow(video: video)
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
                            .listRowBackground(Rectangle().fill(Fanous.surface))
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
        let count = model.selection.count.formatted(.number.locale(l10n.language.locale))
        return ViewThatFits {
            HStack(spacing: FanousScale.spacingMd) { bulkButtons(count) }
            ScrollView(.horizontal) { HStack(spacing: FanousScale.spacingMd) { bulkButtons(count) } }
        }
        .padding(FanousScale.spacingMd)
        .frame(maxWidth: .infinity)
        .background(Fanous.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bulk-bar")
    }

    @ViewBuilder private func bulkButtons(_ count: String) -> some View {
        Text(l10n("studio.content.selected", count)).fanousFont(.label).foregroundStyle(Fanous.textPrimary)
        Spacer(minLength: 0)
        Button(l10n("studio.content.bulkEdit")) { sheet = .edit }.accessibilityIdentifier("bulk-edit")
        Button(l10n("studio.content.bulkSchedule")) { sheet = .schedule }.accessibilityIdentifier("bulk-schedule")
        Button(l10n("studio.content.bulkPlaylist")) { sheet = .playlist }.accessibilityIdentifier("bulk-playlist")
        Button(l10n("studio.content.delete"), role: .destructive) { confirmingDelete = Array(model.selection) }
            .accessibilityIdentifier("bulk-delete")
    }
}

/// One video in the list: thumbnail, title, status and numbers.
struct VideoRow: View {
    @Environment(\.l10n) private var l10n
    let video: StudioVideo

    var body: some View {
        HStack(spacing: FanousScale.spacingMd) {
            ThumbnailImage(url: video.thumbnailURL)
                .frame(width: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                Text(video.displayTitle(l10n.language)).fanousFont(.body).foregroundStyle(Fanous.textPrimary).lineLimit(2)
                Text(details).fanousFont(.caption).foregroundStyle(Fanous.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, FanousScale.spacingXs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("video-\(video.id)")
    }

    private var details: String {
        var parts = [l10n(video.isPublic ? "visibility.public" : "visibility.private")]
        if let date = video.scheduledPublishDate, video.studioStatus == .scheduled {
            parts.append(l10n("studio.content.publishes", date.formatted(.dateTime.locale(l10n.language.locale))))
        } else {
            parts.append(l10n("video.views", DisplayFormat.count(video.views, l10n.language)))
        }
        if let date = video.dateCreated {
            parts.append(date.formatted(.dateTime.day().month().year().locale(l10n.language.locale)))
        }
        return parts.joined(separator: " · ")
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
                // Success messages leave after 5 s; errors stay until dismissed, so they are never missed.
                .task(id: message.key + message.values.joined()) {
                    guard !isError(message.key) else { return }
                    try? await Task.sleep(for: .seconds(5))
                    self.message = nil
                }
                .onTapGesture { self.message = nil }
        }
    }

    private func isError(_ key: String) -> Bool { key.hasPrefix("studio.error.") || key == "studio.content.limit" }

    private func text(_ message: (key: String, values: [String])) -> String {
        let numbers = message.values.map { Int($0).map { $0.formatted(.number.locale(l10n.language.locale)) } ?? $0 }
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

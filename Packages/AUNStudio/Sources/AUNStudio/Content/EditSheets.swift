import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Edit one video's details, see its numbers, or delete it.
struct VideoEditView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    let model: ContentModel
    let video: StudioVideo
    let onDelete: ([String]) -> Void
    @State private var title: String
    @State private var description: String
    @State private var isPublic: Bool
    @State private var category: VideoCategory?
    @State private var language: VideoLanguage?
    @State private var tags: String
    @State private var saving = false

    init(model: ContentModel, video: StudioVideo, onDelete: @escaping ([String]) -> Void) {
        self.model = model
        self.video = video
        self.onDelete = onDelete
        _title = State(initialValue: video.title)
        _description = State(initialValue: video.description ?? "")
        _isPublic = State(initialValue: video.isPublic)
        _category = State(initialValue: video.category.flatMap(VideoCategory.init(rawValue:)))
        _language = State(initialValue: video.language.flatMap(VideoLanguage.init(rawValue:)))
        _tags = State(initialValue: video.tags.joined(separator: ", "))
    }

    /// Only the fields that changed, as the web sends them.
    private var edit: VideoEdit {
        let tagList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return VideoEdit(
            title: trimmedTitle != video.title ? trimmedTitle : nil,
            description: description != (video.description ?? "") ? description : nil,
            isPublic: isPublic != video.isPublic ? isPublic : nil,
            category: category?.rawValue != video.category ? category?.rawValue : nil,
            tags: tagList != video.tags ? tagList : nil,
            language: language?.rawValue != video.language ? language?.rawValue : nil)
    }

    private var hasChanges: Bool { edit != VideoEdit() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(l10n("studio.edit.title"), text: $title).accessibilityIdentifier("edit-title")
                    TextField(l10n("studio.upload.description"), text: $description, axis: .vertical).lineLimit(3...10)
                        .accessibilityIdentifier("edit-description")
                    Toggle(l10n("visibility.public"), isOn: $isPublic).accessibilityIdentifier("edit-public")
                    Picker(l10n("studio.upload.category"), selection: $category) {
                        Text(l10n("studio.upload.none")).tag(VideoCategory?.none)
                        ForEach(VideoCategory.allCases, id: \.self) {
                            Text(l10n("category.\($0.rawValue)")).tag(VideoCategory?.some($0))
                        }
                    }
                    Picker(l10n("studio.upload.language"), selection: $language) {
                        Text(l10n("studio.upload.none")).tag(VideoLanguage?.none)
                        ForEach(VideoLanguage.allCases, id: \.self) {
                            Text(l10n("videoLanguage.\($0.rawValue)")).tag(VideoLanguage?.some($0))
                        }
                    }
                    LabeledField(
                        label: l10n("studio.upload.tags"), text: $tags, prompt: l10n("studio.upload.tagsHint"),
                        identifier: "edit-tags")
                }
                .studioRows()
                Section(l10n("studio.analytics.title")) { VideoStatsView(services: model.services, videoID: video.id) }
                    .studioRows()
                Section {
                    Button(l10n("studio.content.delete"), role: .destructive) { onDelete([video.id]) }
                        .foregroundStyle(Fanous.errorText)
                        .accessibilityIdentifier("edit-delete")
                } footer: {
                    Text(l10n("studio.content.deleteFooter"))
                }
                .studioRows()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .fanousPage()
            .navigationTitle(l10n("studio.edit.heading"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n("common.cancel")) { dismiss() }.accessibilityIdentifier("edit-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n("studio.edit.save")) {
                        Task {
                            saving = true
                            if await model.save(video.id, edit) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(!hasChanges || saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("edit-save")
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 600)
        #endif
    }
}

/// Visibility, category and tags for every selected video (`bulk-update`). Untouched fields stay as they are.
struct BulkEditView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    let model: ContentModel
    @State private var visibility: UploadVisibility?
    @State private var category: VideoCategory?
    @State private var addTags = ""
    @State private var removeTags = ""

    private func list(_ text: String) -> [String]? {
        let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    private var changes: BulkChanges {
        BulkChanges(
            isPublic: visibility.map { $0 == .public }, category: category?.rawValue, addTags: list(addTags),
            removeTags: list(removeTags))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(l10n("studio.upload.visibility"), selection: $visibility) {
                        Text(l10n("studio.bulk.unchanged")).tag(UploadVisibility?.none)
                        Text(l10n("visibility.public")).tag(UploadVisibility?.some(.public))
                        Text(l10n("visibility.private")).tag(UploadVisibility?.some(.private))
                    }
                    .accessibilityIdentifier("bulk-visibility")
                    Picker(l10n("studio.upload.category"), selection: $category) {
                        Text(l10n("studio.bulk.unchanged")).tag(VideoCategory?.none)
                        ForEach(VideoCategory.allCases, id: \.self) {
                            Text(l10n("category.\($0.rawValue)")).tag(VideoCategory?.some($0))
                        }
                    }
                    .accessibilityIdentifier("bulk-category")
                    LabeledField(
                        label: l10n("studio.bulk.addTags"), text: $addTags, prompt: l10n("studio.upload.tagsHint"),
                        identifier: "bulk-add-tags")
                    LabeledField(
                        label: l10n("studio.bulk.removeTags"), text: $removeTags, prompt: l10n("studio.upload.tagsHint"),
                        identifier: "bulk-remove-tags")
                } footer: {
                    Text(l10n("studio.bulk.footer", model.selection.count.formatted(.number.locale(l10n.language.locale))))
                }
                .studioRows()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .fanousPage()
            .navigationTitle(l10n("studio.content.bulkEdit"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(l10n("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n("studio.bulk.apply")) {
                        let changes = changes
                        dismiss()
                        Task { await model.bulkUpdate(changes) }
                    }
                    .disabled(changes.isEmpty)
                    .accessibilityIdentifier("bulk-apply")
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}

/// Publish the selection one after another from a start time (`bulk-schedule`).
struct BulkScheduleView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    let model: ContentModel
    @State private var start = UploadComposer.earliestSchedule()
    @State private var intervalHours = 24

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        l10n("studio.upload.publishAt"), selection: $start,
                        in: Date().addingTimeInterval(UploadComposer.minimumLead)...)
                    Stepper(
                        l10n("studio.upload.interval", intervalHours.formatted(.number.locale(l10n.language.locale))),
                        value: $intervalHours, in: 0...168)
                } footer: {
                    Text(l10n("studio.upload.scheduleHelp"))
                }
                .studioRows()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .fanousPage()
            .navigationTitle(l10n("studio.content.bulkSchedule"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(l10n("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n("studio.bulk.apply")) {
                        let (start, minutes) = (start, intervalHours * 60)
                        dismiss()
                        Task { await model.bulkSchedule(startAt: start, intervalMinutes: minutes) }
                    }
                    .accessibilityIdentifier("bulk-schedule-apply")
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 260)
        #endif
    }
}

/// Add the selection to one of the channel's playlists.
struct PlaylistPickView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    let model: ContentModel
    @State private var playlists: [StudioPlaylist] = []
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if failed { Text(l10n("common.error.load")).foregroundStyle(Fanous.errorText) }
                ForEach(playlists) { playlist in
                    Button {
                        dismiss()
                        Task { await model.addSelection(toPlaylist: playlist.id) }
                    } label: {
                        Label(playlist.title, systemImage: playlist.isPublic ? "list.bullet" : "lock")
                    }
                    .accessibilityIdentifier("pick-playlist-\(playlist.id)")
                }
                .listRowBackground(Rectangle().fill(Fanous.surface))
            }
            .scrollContentBackground(.hidden)
            .fanousPage()
            .navigationTitle(l10n("studio.content.bulkPlaylist"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(l10n("common.cancel")) { dismiss() } } }
            .task {
                do {
                    playlists = try await model.services.studio.playlists(channelID: model.channelID)
                } catch {
                    failed = true
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}

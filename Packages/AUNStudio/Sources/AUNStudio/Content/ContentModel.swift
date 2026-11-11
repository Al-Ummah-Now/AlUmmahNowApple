import AUNCoreBridge
import Foundation
import Observation

/// The Content screen: one status tab of a channel's videos, search with live suggestions, selection and actions.
@MainActor @Observable
final class ContentModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed }

    var status: StudioStatus = .published { didSet { if status != oldValue { selection = []; reload() } } }
    var sort: ContentSort = .newest { didSet { if sort != oldValue { reload() } } }
    var searchText = "" { didSet { if searchText != oldValue { textChanged() } } }
    private(set) var items: [StudioVideo] = []
    private(set) var counts: ContentCounts = [:]
    private(set) var state: LoadState = .idle
    private(set) var cursor: String?
    private(set) var suggestions: [StudioSuggestion] = []
    var selection: Set<String> = []
    /// The outcome of the last action, as an L10n key and its arguments.
    var message: (key: String, values: [String])?

    let channelID: String
    let services: StudioServices
    private var loadTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?
    /// The web Studio waits 300 ms after typing; suggestions start at 2 characters, as everywhere else.
    static let debounce = Duration.milliseconds(300)

    init(channelID: String, services: StudioServices) {
        self.channelID = channelID
        self.services = services
    }

    var selected: [StudioVideo] { items.filter { selection.contains($0.id) } }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { await load(reset: true) }
    }

    func loadMore() async {
        guard cursor != nil, state != .loading else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        state = .loading
        let query = ContentQuery(status: status, text: searchText, sort: sort)
        do {
            async let page = services.studio.content(channelID: channelID, query: query, cursor: reset ? nil : cursor)
            async let counts = services.studio.contentCounts(channelID: channelID)
            let result = try await page
            try Task.checkCancellation()
            items = reset ? result.items : items + result.items
            cursor = result.cursor
            self.counts = (try? await counts) ?? self.counts
            selection = selection.intersection(items.map(\.id))
            state = .loaded
        } catch is CancellationError {
        } catch {
            AUNLog.studio.error("Loading content failed: \(error)")
            state = .failed
        }
    }

    private func textChanged() {
        suggestTask?.cancel()
        let text = searchText
        suggestTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            reload()
            await suggest(text)
        }
    }

    /// Server suggestions (public videos and completions in this channel) after the channel's own matches, which
    /// include drafts and private videos the server never suggests.
    func suggest(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            suggestions = []
            return
        }
        let search = services.search
        let local = items.filter {
            search.matches($0.title, query: trimmed) || search.matches($0.titleLocalized?.ar ?? "", query: trimmed)
        }
        .prefix(5).map { StudioSuggestion(text: $0.title, kind: .video, itemID: $0.id) }
        let remote = (try? await search.suggestions(trimmed, channelID: channelID)) ?? []
        guard !Task.isCancelled, trimmed == searchText.trimmingCharacters(in: .whitespaces) else { return }
        var seen = Set<String>()
        suggestions = (local + remote).filter { seen.insert($0.text.lowercased()).inserted }.prefix(8).map { $0 }
    }

    // MARK: Actions

    private func finish(_ result: BulkResult, done key: String) {
        message =
            result.failed.isEmpty
            ? (key, [String(result.succeeded)])
            : ("studio.content.partial", [String(result.succeeded), String(result.failed.count)])
        selection = []
        reload()
    }

    private func perform(_ key: String, _ action: () async throws -> BulkResult) async {
        do {
            finish(try await action(), done: key)
        } catch {
            message = (
                UploadQueue.failureKey(error) == "studio.upload.error.limit" ? "studio.content.limit" : "studio.error.generic", []
            )
        }
    }

    func delete(_ ids: [String]) async {
        await perform("studio.content.deleted") { try await services.studio.deleteVideos(ids, channelID: channelID) }
    }

    func bulkUpdate(_ changes: BulkChanges) async {
        guard !changes.isEmpty else { return }
        let ids = Array(selection)
        await perform("studio.content.updated") { try await services.studio.bulkUpdate(ids, changes, channelID: channelID) }
    }

    func bulkSchedule(startAt: Date, intervalMinutes: Int) async {
        let ids = selected.map(\.id)
        await perform("studio.content.scheduled") {
            try await services.studio.bulkSchedule(ids, startAt: startAt, intervalMinutes: intervalMinutes, timeZone: .current)
        }
    }

    func addSelection(toPlaylist playlistID: String) async {
        let ids = selected.map(\.id)
        do {
            try await services.studio.addToPlaylist(playlistID, videoIDs: ids, channelID: channelID)
            message = ("studio.content.addedToPlaylist", [String(ids.count)])
            selection = []
        } catch {
            message = ("studio.error.generic", [])
        }
    }

    func save(_ id: String, _ edit: VideoEdit) async -> Bool {
        do {
            try await services.studio.updateVideo(id, edit, channelID: channelID)
            message = ("studio.content.saved", [])
            reload()
            return true
        } catch {
            message = ((error as? CoreError) == .forbidden ? "studio.error.forbidden" : "studio.error.generic", [])
            return false
        }
    }
}

/// Recently deleted: restore, or delete permanently (queued for the hourly cleanup).
@MainActor @Observable
final class DeletedModel {
    private(set) var items: [DeletedVideo] = []
    private(set) var failed = false
    private(set) var loaded = false
    var selection: Set<String> = []
    var message: (key: String, values: [String])?

    let channelID: String
    let services: StudioServices

    init(channelID: String, services: StudioServices) {
        self.channelID = channelID
        self.services = services
    }

    func load() async {
        do {
            var all: [DeletedVideo] = []
            var cursor: String?
            repeat {
                let page = try await services.studio.deletedVideos(channelID: channelID, cursor: cursor)
                all += page.items
                cursor = page.cursor
            } while cursor != nil && all.count < 500
            items = all.filter { $0.status != .purged }
            failed = false
        } catch {
            failed = true
        }
        loaded = true
        selection = selection.intersection(items.map(\.id))
    }

    func restore(_ ids: [String]) async {
        await run("studio.deleted.restored") { try await services.studio.restoreVideos(ids) }
    }

    func purge(_ ids: [String]) async {
        await run("studio.deleted.purged") { try await services.studio.purgeVideos(ids) }
    }

    private func run(_ key: String, _ action: () async throws -> BulkResult) async {
        do {
            let result = try await action()
            message =
                result.failed.isEmpty
                ? (key, [String(result.succeeded)])
                : ("studio.content.partial", [String(result.succeeded), String(result.failed.count)])
        } catch {
            message = ("studio.error.generic", [])
        }
        selection = []
        await load()
    }
}

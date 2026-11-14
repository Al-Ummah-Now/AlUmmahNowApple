import AUNCoreBridge
import Foundation
import Observation

/// The review queue (Action needed / History): text only, kept in memory, so it still shows offline.
@MainActor @Observable
public final class QueueModel {
    public var tab: ReviewTab = .actionNeeded {
        didSet { if tab != oldValue { Task { await load() } } }
    }
    public private(set) var items: [ReviewItem] = []
    public private(set) var isLoading = false
    public private(set) var isOffline = false
    public private(set) var lastUpdated: Date?
    public private(set) var failed = false
    public private(set) var query = ""

    let service: any ReviewServicing
    let senior: Bool
    private var searchTask: Task<Void, Never>?
    private var loaded: [ReviewTab: [ReviewItem]] = [:]

    public init(service: any ReviewServicing, senior: Bool) {
        self.service = service
        self.senior = senior
    }

    /// Action needed: escalations first for seniors, then the SLA deadline, then risk. History: newest decision first.
    public static func sorted(_ items: [ReviewItem], tab: ReviewTab, senior: Bool) -> [ReviewItem] {
        switch tab {
        case .actionNeeded:
            return items.sorted { a, b in
                if senior, a.escalate != b.escalate { return a.escalate }
                let da = a.slaDueAt ?? .distantFuture
                let db = b.slaDueAt ?? .distantFuture
                if da != db { return da < db }
                if (a.risk ?? 0) != (b.risk ?? 0) { return (a.risk ?? 0) > (b.risk ?? 0) }
                return a.id < b.id
            }
        case .history:
            return items.sorted { ($0.decidedAt ?? .distantPast) > ($1.decidedAt ?? .distantPast) }
        }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        let tab = tab
        let query = query
        LaunchClock.mark("queue load started")
        do {
            let page = try await service.queue(tab, query: query.isEmpty ? nil : query, cursor: nil)
            LaunchClock.mark("queue loaded \(page.items.count)")
            guard tab == self.tab, query == self.query else { return }
            items = Self.sorted(page.items, tab: tab, senior: senior)
            if query.isEmpty { loaded[tab] = items }
            isOffline = false
            failed = false
            lastUpdated = Date()
        } catch CoreError.offline {
            isOffline = true
            if items.isEmpty, let cached = loaded[tab] { items = cached }
        } catch {
            AUNLog.admin.error("Queue failed: \(error)")
            failed = true
        }
    }

    /// Loads unless a load finished in the last few seconds: the staff check has just loaded it when the shell opens.
    public func refresh(within seconds: TimeInterval = 5) async {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < seconds { return }
        await load()
    }

    /// Live search over titles, channels and reasons, as the person types (250 ms debounce).
    public func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    /// Autocomplete suggestions. With nothing typed they open with the queue's own titles and channels.
    public func suggestions(for text: String, limit: Int = 6) -> [String] {
        let source = loaded[tab] ?? items
        let words = source.flatMap { [$0.title, $0.channelName, $0.topCategory].compactMap { $0 } }
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0.lowercased()).inserted }
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(unique.prefix(limit)) }
        return Array(unique.filter { $0.lowercased().contains(q) && $0.lowercased() != q }.prefix(limit))
    }

    /// A decision moved an item; the server stays the source of truth on the next load.
    public func apply(_ item: ReviewItem) {
        items.removeAll { $0.id == item.id }
        let belongs = tab == .actionNeeded ? item.isOpen : item.decidedAt != nil
        if belongs { items = Self.sorted(items + [item], tab: tab, senior: senior) }
        loaded[tab] = items
    }

    public func item(after id: String?, step: Int) -> ReviewItem? {
        guard !items.isEmpty else { return nil }
        guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return items.first }
        let next = index + step
        return items.indices.contains(next) ? items[next] : nil
    }
}

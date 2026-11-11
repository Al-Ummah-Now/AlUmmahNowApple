import Foundation

/// One autocomplete row.
public struct StudioSuggestion: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case query, video, channel, playlist, category }

    public var text: String
    public var kind: Kind
    /// Set for items (a video opens its editor); nil runs a search for `text`.
    public var itemID: String?
    public var subtitle: String?
    public var id: String { "\(kind.rawValue):\(itemID ?? text)" }

    public init(text: String, kind: Kind, itemID: String? = nil, subtitle: String? = nil) {
        self.text = text
        self.kind = kind
        self.itemID = itemID
        self.subtitle = subtitle
    }
}

/// Live search autocomplete (`GET /api/search/suggestions`) and the shared Arabic-aware matching rules.
/// `aun-search` implements it.
public protocol SearchSuggesting: Sendable {
    /// Suggestions for what the person typed, limited to one channel when given. The server only returns public items.
    func suggestions(_ text: String, channelID: String?) async throws -> [StudioSuggestion]
    /// Whether `text` matches `query` the way the server's search does (diacritics, alef forms, digits).
    func matches(_ text: String, query: String) -> Bool
}

/// Suggestions from the fixture titles, with plain case-insensitive matching.
public struct FixtureSearchService: SearchSuggesting {
    public init() {}

    public func suggestions(_ text: String, channelID: String?) async throws -> [StudioSuggestion] {
        let titles = ["Tafsir of Surah Al-Kahf, part 1", "Tafsir of Surah Al-Kahf, part 2", "Friday khutbah: patience"]
        return titles.filter { matches($0, query: text) }.map { StudioSuggestion(text: $0, kind: .query) }
    }

    public func matches(_ text: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

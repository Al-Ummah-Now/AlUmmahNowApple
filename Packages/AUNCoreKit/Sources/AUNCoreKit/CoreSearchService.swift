import AUNCoreBridge
import AunCore
import Foundation

/// `SearchSuggesting` on aun-search: the suggestions client and the server's normalisation rules.
public final class CoreSearchService: SearchSuggesting, @unchecked Sendable {
    private let accounts: CoreAccountService
    private let baseURL: URL
    private let lock = NSLock()
    private var client: (account: String, api: ApiClient)?

    public init(accounts: CoreAccountService, baseURL: URL) {
        self.accounts = accounts
        self.baseURL = baseURL
    }

    /// One client per account, rebuilt after an account switch.
    private func api() throws -> ApiClient {
        let active = try accounts.manager.activeAccount()?.userId ?? ""
        return try lock.withLock {
            if let client, client.account == active { return client.api }
            let config = ApiClientConfig(
                baseUrl: baseURL.absoluteString, userAgent: "AlUmmahNowStudio-Apple", locale: nil, timeoutMs: 8000,
                maxAttempts: 1)
            let api = try accounts.manager.apiClient(config: config, userId: active.isEmpty ? nil : active)
            client = (active, api)
            return api
        }
    }

    public func suggestions(_ text: String, channelID: String?) async throws -> [StudioSuggestion] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        do {
            let rows = try await api().searchSuggestions(
                query: SuggestionQuery(text: text, limit: 8, kinds: [.query, .video], channelId: channelID))
            return rows.map { row in
                StudioSuggestion(
                    text: row.text, kind: Self.kind(row.kind), itemID: row.opensItem ? row.id : nil, subtitle: row.subtitle)
            }
        } catch let error as AunError {
            throw CoreError(error)
        }
    }

    public func matches(_ text: String, query: String) -> Bool { searchMatches(text: text, query: query) }

    static func kind(_ kind: SuggestionKind) -> StudioSuggestion.Kind {
        switch kind {
        case .query: .query
        case .video: .video
        case .channel: .channel
        case .playlist: .playlist
        case .category: .category
        }
    }
}

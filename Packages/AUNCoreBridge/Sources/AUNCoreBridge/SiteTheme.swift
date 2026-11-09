import Foundation

/// Reads the site theme an admin sets (`site.theme`). The value is a theme id; callers reduce unknown ids
/// to the fallback, as the web does.
public protocol SiteThemeServicing: Sendable {
    func siteTheme() async throws -> String
}

/// `GET {adminAPI}/public/site-theme` → `{"theme":"fawanees"}`. Public, no credentials.
public struct NativeSiteThemeService: SiteThemeServicing {
    private let endpoint: URL
    private let session: URLSession

    public init(adminAPIBaseURL: URL, session: URLSession = .shared) {
        endpoint = adminAPIBaseURL.appending(path: "public/site-theme")
        self.session = session
    }

    private struct Body: Decodable { let theme: String }

    public func siteTheme() async throws -> String {
        var request = URLRequest(url: endpoint, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw CoreError.decoding }
        return body.theme
    }
}

/// A fixed answer, for fixtures, snapshots and previews.
public struct FixedSiteThemeService: SiteThemeServicing {
    private let value: String
    public init(_ value: String) { self.value = value }
    public func siteTheme() async throws -> String { value }
}

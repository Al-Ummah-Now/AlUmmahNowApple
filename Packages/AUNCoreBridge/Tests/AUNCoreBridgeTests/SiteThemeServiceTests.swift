import Foundation
import Testing

@testable import AUNCoreBridge

@Suite struct SiteThemeServiceTests {
    private let admin = URL(string: "https://admin.test")!

    @Test func readsThePublicSiteThemeEndpoint() async throws {
        let session = StubURLProtocol.session { request in
            #expect(request.url?.absoluteString == "https://admin.test/public/site-theme")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, ["Content-Type": "application/json"], Data(#"{"theme":"zujaj"}"#.utf8))
        }
        #expect(try await NativeSiteThemeService(adminAPIBaseURL: admin, session: session).siteTheme() == "zujaj")
    }

    @Test func surfacesHTTPAndBodyErrors() async {
        let missing = StubURLProtocol.session { _ in (404, [:], Data()) }
        await #expect(throws: CoreError.http(status: 404)) {
            _ = try await NativeSiteThemeService(adminAPIBaseURL: admin, session: missing).siteTheme()
        }
        let garbage = StubURLProtocol.session { _ in (200, [:], Data("<html>".utf8)) }
        await #expect(throws: CoreError.decoding) {
            _ = try await NativeSiteThemeService(adminAPIBaseURL: admin, session: garbage).siteTheme()
        }
    }

    @Test func environmentReadsTheAdminAPIFromInfoAndNeverLeavesHTTPS() {
        let info: [String: Any] = [
            "AUNAPIBaseURL": "https://videos.api.alummahnow.net", "AUNEnvironment": "prod",
            "AUNAdminAPIBaseURL": "https://admin.api.alummahnow.net",
        ]
        #expect(AppEnvironment.fromInfoDictionary(info).adminAPIBaseURL.absoluteString == "https://admin.api.alummahnow.net")
        var plain = info
        plain["AUNAdminAPIBaseURL"] = "http://admin.api.alummahnow.net"
        #expect(AppEnvironment.fromInfoDictionary(plain).adminAPIBaseURL == AppEnvironment.qaAdminAPI)
    }
}

import AUNCoreBridge
import Foundation
import Testing

@testable import AUNFeatures

@Suite struct FeaturesInjectionAuditTests {
    @Test func viewerReportURLRejectsUnsafeBaseSchemeAndUserinfo() {
        let url = ViewerReportURL.video(
            id: "v1", language: "en", webBaseURL: URL(string: "javascript://user@evil.example/%0aalert(1)")!)
        #expect(url.scheme == "https")
        #expect(url.host == AppEnvironment.qa.webBaseURL.host)
        #expect(url.user == nil)
    }
}

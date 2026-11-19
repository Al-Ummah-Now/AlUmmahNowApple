import Foundation
import Testing

@testable import AUNCoreBridge

struct AUNClientTests {
    @Test func namesTheAppVersionAndOS() {
        #expect(
            AUNClient.make(bundleID: "net.alummahnow.studio", version: "1.4.0", os: ("iPadOS", "18.1"))
                == "aun-studio/1.4.0 (iPadOS 18.1)")
        #expect(
            AUNClient.make(bundleID: "net.alummahnow.admin", version: "2.0", os: ("macOS", "15.2"))
                == "aun-admin/2.0 (macOS 15.2)")
        #expect(
            AUNClient.make(bundleID: "net.alummahnow.videos", version: "1.0", os: ("tvOS", "18.0")) == "aun-apple/1.0 (tvOS 18.0)"
        )
    }

    @Test func keepsOnlyHeaderSafeCharacters() {
        #expect(AUNClient.make(bundleID: nil, version: "1.0 (beta)", os: ("iOS", "18.1")) == "aun-apple/1.0beta (iOS 18.1)")
        #expect(AUNClient.make(bundleID: nil, version: nil, os: ("iOS", "18.1")) == "aun-apple/0 (iOS 18.1)")
    }

    @Test func requestsCarryTheHeader() {
        var request = URLRequest(url: URL(string: "https://videos.api.qa.alummahnow.net/api/videos")!)
        request.setAUNClient()
        #expect(request.value(forHTTPHeaderField: "X-AUN-Client") == AUNClient.value)
    }
}

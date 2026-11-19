#if os(macOS)
    import AUNCoreBridge
    import Foundation
    import Testing

    @testable import AUNDesign

    struct AppKitLayoutDirectionTests {
        @Test func arabicMirrorsTheChromeAndKeepsLaunchArguments() throws {
            let defaults = try #require(UserDefaults(suiteName: "AppKitLayoutDirectionTests"))
            let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
            defaults.setVolatileDomain(["AUNLanguage": "ar"], forName: UserDefaults.argumentDomain)
            AppKitLayoutDirection.match(.ar, defaults: defaults)
            #expect(defaults.bool(forKey: "AppleTextDirection"))
            #expect(defaults.bool(forKey: "NSForceRightToLeftWritingDirection"))
            #expect(defaults.string(forKey: "AUNLanguage") == "ar")
            AppKitLayoutDirection.match(.en, defaults: defaults)
            #expect(!defaults.bool(forKey: "NSForceRightToLeftWritingDirection"))
        }
    }
#endif

import AUNCoreBridge
import Foundation

public enum ViewerBootstrap {
    /// `-AUNUseFixtures YES` selects hermetic data for UI tests.
    public static func makeCore(defaults: UserDefaults = .standard, info: [String: Any]? = Bundle.main.infoDictionary)
        -> CoreBridge
    {
        if defaults.bool(forKey: "AUNUseFixtures") { return .fixtures() }
        return .temporaryNative(environment: .fromInfoDictionary(info))
    }
}

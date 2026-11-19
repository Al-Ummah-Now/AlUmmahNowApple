import Foundation

/// The `X-AUN-Client` header (AlUmmahNow request origin, wiki AUN-ORIGIN): which app, app version
/// and OS sends a request, e.g. `aun-studio/1.4.0 (iPadOS 18.1)`. The servers count requests by
/// it for errors and analytics. It carries no identifier: no device id, no user, no install.
public enum AUNClient {
    public static let headerName = "X-AUN-Client"

    /// This process's value, worked out once.
    public static let value: String = make(
        bundleID: Bundle.main.bundleIdentifier, version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        os: currentOS())

    /// `aun-<app>/<version> (<os> <os version>)`; every part is reduced to the characters the
    /// servers (and aun-core) accept.
    static func make(bundleID: String?, version: String?, os: (name: String, version: String)) -> String {
        let id = (bundleID ?? "").lowercased()
        let app = id.contains("admin") ? "aun-admin" : id.contains("studio") ? "aun-studio" : "aun-apple"
        let appVersion = token(version ?? "").isEmpty ? "0" : token(version ?? "")
        return "\(app)/\(appVersion) (\(os.name) \(token(os.version)))"
    }

    static func token(_ text: String) -> String {
        String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_+".contains($0)) }.prefix(40))
    }

    /// The OS name the servers map to a surface: iOS, iPadOS, macOS or tvOS.
    static func currentOS() -> (name: String, version: String) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion)"
        #if os(macOS)
            return ("macOS", version)
        #elseif os(tvOS)
            return ("tvOS", version)
        #elseif os(iOS)
            if ProcessInfo.processInfo.isiOSAppOnMac { return ("macOS", version) }
            return (isPad() ? "iPadOS" : "iOS", version)
        #else
            return ("unknown", version)
        #endif
    }

    /// iPad or iPhone from the hardware model (no UIKit, so any thread may ask).
    static func isPad() -> Bool {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated.hasPrefix("iPad")
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.hasPrefix("iPad")
    }
}

extension URLRequest {
    /// Adds `X-AUN-Client` (see `AUNClient`).
    public mutating func setAUNClient() { setValue(AUNClient.value, forHTTPHeaderField: AUNClient.headerName) }
}

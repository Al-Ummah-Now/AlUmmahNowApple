import AUNCoreBridge
import Foundation
import SwiftUI

/// Looks up strings for an explicit language, so the app can switch language without relaunching.
public struct L10n: Sendable {
    public let language: AppLanguage
    private let bundle: Bundle

    public init(_ language: AppLanguage) {
        self.language = language
        bundle = Bundle.module.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
    }

    public func callAsFunction(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: "⟦\(key)⟧", table: nil)
    }

    public func callAsFunction(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: self(key), locale: language.locale, arguments: arguments)
    }

    func containsKey(_ key: String) -> Bool { !self(key).hasPrefix("⟦") }

    /// All keys defined for the language; used by the parity test.
    var allKeys: Set<String> {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
            let dictionary = NSDictionary(contentsOf: url) as? [String: String]
        else { return [] }
        return Set(dictionary.keys)
    }
}

extension EnvironmentValues {
    @Entry public var l10n = L10n(.en)
}

/// Locale-aware display formatting for server numbers and times.
public enum DisplayFormat {
    public static func count(_ value: Int, _ language: AppLanguage) -> String {
        value.formatted(.number.notation(.compactName).locale(language.locale))
    }

    public static func duration(_ seconds: Double, _ language: AppLanguage) -> String {
        let total = max(0, Int(seconds.rounded()))
        let numbers = IntegerFormatStyle<Int>.number.grouping(.never).locale(language.locale)
        func pad(_ value: Int) -> String {
            let zero = 0.formatted(numbers)
            let text = value.formatted(numbers)
            return value < 10 ? zero + text : text
        }
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        if hours > 0 { return "\(hours.formatted(numbers)):\(pad(minutes)):\(pad(secs))" }
        return "\(minutes.formatted(numbers)):\(pad(secs))"
    }
}

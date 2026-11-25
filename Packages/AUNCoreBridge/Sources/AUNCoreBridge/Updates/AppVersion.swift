import Foundation

/// An app version as the servers and aun-core compare it (wiki AUN-APP-UPDATES §2.1): 3 or 4 numeric parts (a missing
/// 4th is 0), an optional semver pre-release and optional build metadata, which is ignored.
public struct AppVersion: Comparable, Hashable, Sendable {
    private let numbers: [Int]
    private let preRelease: [String]?

    /// Nil when the text isn't a version the API takes.
    public init?(_ text: String) {
        guard text.allSatisfy({ $0.isASCII }) else { return nil }
        var rest = Substring(text)
        if let plus = rest.firstIndex(of: "+") {
            let build = rest[rest.index(after: plus)...]
            guard !build.isEmpty, build.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
            rest = rest[..<plus]
        }
        var identifiers: [String]?
        if let dash = rest.firstIndex(of: "-") {
            let parts = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else {
                return nil
            }
            identifiers = parts.map(String.init)
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (3...4).contains(parts.count), parts.allSatisfy({ (1...6).contains($0.count) && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return nil }
        numbers = values + Array(repeating: 0, count: 4 - values.count)
        preRelease = identifiers
    }

    /// The version this build reports: the marketing version and the rebuild number `N` of a `vX.Y.Z-N` tag, which
    /// `scripts/release-version.sh` puts in the last two digits of the build number.
    public static func installed(shortVersion: String?, build: String?) -> String? {
        guard let shortVersion, AppVersion(shortVersion) != nil else { return nil }
        guard let build, let number = Int(build), number >= 0 else { return "\(shortVersion).0" }
        return "\(shortVersion).\(number % 100)"
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    /// Equal versions hash alike (a pre-release's leading zeros don't count when comparing).
    public func hash(into hasher: inout Hasher) { hasher.combine(numbers) }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for (l, r) in zip(lhs.numbers, rhs.numbers) where l != r { return l < r }
        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, _): return false
        case (_, nil): return true
        case (let l?, let r?): return precedes(l, r)
        }
    }

    /// Semver §11: numeric identifiers by value and below words; a longer list wins when the shorter is its start.
    private static func precedes(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (l, r) in zip(lhs, rhs) where l != r {
            switch (l.allSatisfy(\.isNumber), r.allSatisfy(\.isNumber)) {
            case (true, true):
                // Digits only: the longer number (without leading zeros) is the larger one, whatever its size
                let (x, y) = (l.drop { $0 == "0" }, r.drop { $0 == "0" })
                if x == y { continue }
                return x.count == y.count ? x < y : x.count < y.count
            case (true, false): return true
            case (false, true): return false
            case (false, false): return l < r
            }
        }
        return lhs.count < rhs.count
    }
}

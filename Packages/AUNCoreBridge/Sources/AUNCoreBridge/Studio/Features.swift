import Foundation

/// A user-facing feature the server may switch off for this person (`GET /api/me/features`, shared-types
/// `USER_FEATURE_KEYS`). Off means invisible: no tab, button or text about it.
public enum UserFeature: String, CaseIterable, Sendable {
    case upload, createChannel, live, captionsTranscribe, captionsTranslate, inlineTranslate, viewerTranslatedTitles
    case quranEditions, quranText, audioTracks, siteDomains, socialAutopost, youtubeImport, aiCategorySuggest, bulkSchedule
}

/// Which features this person sees, from `GET /api/me/features[?channelId=]`. Fails closed: a key that is missing,
/// unknown to the app or anything but `true` is off.
public struct UserFeatures: Hashable, Sendable, Decodable {
    public private(set) var on: Set<UserFeature>

    public init(on: Set<UserFeature> = []) { self.on = on }

    /// Every feature off: what Studio uses while it cannot read the answer.
    public static let none = UserFeatures()
    /// Every feature on, for fixtures and previews.
    public static let all = UserFeatures(on: Set(UserFeature.allCases))

    public func isOn(_ feature: UserFeature) -> Bool { on.contains(feature) }

    public func with(_ feature: UserFeature, _ isOn: Bool) -> UserFeatures {
        var copy = self
        if isOn { copy.on.insert(feature) } else { copy.on.remove(feature) }
        return copy
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Reads `{ "version": 1, "features": { … } }`, the same under `data` or `result`, or the flags at the top level.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        for wrapper in ["data", "result", "features"] {
            let key = AnyKey(stringValue: wrapper)
            if c.contains(key), let nested = try? c.decode(UserFeatures.self, forKey: key) {
                self = nested
                return
            }
        }
        on = Set(
            UserFeature.allCases.filter { feature in
                (try? c.decodeIfPresent(Bool.self, forKey: AnyKey(stringValue: feature.rawValue))) == true
            })
    }
}

import AUNCoreBridge
import AunCore
import Testing

@testable import AUNCoreKit

/// Real accounts are named by aun-core: display name, else first + last; the app then falls back to email. An @handle
/// is never a name.
struct DisplayNameTests {
    @Test func coreResolvesDisplayNameThenFirstAndLast() {
        let both = NameFields(displayName: "Aisha R.", firstName: "Aisha", lastName: "Rahman")
        #expect(resolveDisplayName(fields: both, locale: "en") == "Aisha R.")
        #expect(resolveDisplayName(fields: NameFields(firstName: "Aisha", lastName: "Rahman"), locale: "en") == "Aisha Rahman")
        #expect(resolveDisplayName(fields: NameFields(), locale: "en") == "")
    }

    @Test func profilesPreferTheServersResolvedNameAndNeverTheHandle() {
        let resolved = #"{"resolvedDisplayName":"Maryam Haddad","displayName":"Maryam","username":"maryam_h"}"#
        #expect(resolveDisplayNameJson(profileJson: resolved, locale: "en") == "Maryam Haddad")
        let named = #"{"firstName":"Omar","lastName":"Saleh","username":"omar99"}"#
        #expect(resolveDisplayNameJson(profileJson: named, locale: "en") == "Omar Saleh")
        #expect(resolveDisplayNameJson(profileJson: #"{"username":"omar99","handle":"@omar99"}"#, locale: "en") == "")
    }

    @Test func accountsFallBackToEmail() {
        let named = AccountInfo(
            userId: "u1", email: "a@x.test", displayName: "Aisha Rahman", avatarUrl: nil, activeChannelId: nil,
            needsReauth: false, addedAtMs: 0, lastUsedAtMs: 0)
        #expect(StudioAccount(named).name == "Aisha Rahman")
        var unnamed = named
        unnamed.displayName = nil
        #expect(StudioAccount(unnamed).name == "a@x.test")
    }
}

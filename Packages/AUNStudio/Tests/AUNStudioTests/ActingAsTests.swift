import AUNCoreBridge
import AUNDesign
import Testing

@testable import AUNStudio

/// The "Acting as" picker names each channel identity with its name, a "Channel" tag and the role.
struct ActingAsTests {
    private let channel = StudioChannel(
        id: "c", name: "Tafsir Circle", nameLocalized: LocalizedText(en: "Tafsir Circle", ar: "حلقة التفسير"),
        role: .editor)

    @Test func englishWording() {
        let l10n = L10n(.en)
        #expect(l10n("studio.actingAs.title") == "Acting as")
        #expect(ChannelPicker.identityLabel(channel, l10n) == "Tafsir Circle · Channel · Editor")
    }

    @Test func arabicWording() {
        let l10n = L10n(.ar)
        #expect(l10n("studio.actingAs.title") == "تتصرّف باسم")
        #expect(ChannelPicker.identityLabel(channel, l10n) == "حلقة التفسير · قناة · محرر")
    }

    @Test func neverCallsTheIdentityNone() {
        for language in [AppLanguage.en, .ar] {
            let l10n = L10n(language)
            for key in ["studio.actingAs.title", "studio.actingAs.channel"] {
                let text = l10n(key).lowercased()
                #expect(!text.contains("none") && !text.contains("no channel") && !text.contains("فيديو"))
            }
        }
    }
}

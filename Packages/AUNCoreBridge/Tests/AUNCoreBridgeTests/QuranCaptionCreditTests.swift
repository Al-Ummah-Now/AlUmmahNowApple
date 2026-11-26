import Testing

@testable import AUNCoreBridge

struct QuranCaptionCreditTests {
    @Test(arguments: [
        "Source: Quran Foundation",
        "Source: Quran Foundation  ",
        "Quran data provided by Quran Foundation (https://quran.foundation/)",
        "Quran data provided by Quran\u{00A0}Foundation\u{00A0}(https://quran.foundation/)",
    ])
    func englishCredit(line: String) {
        let cue = QuranCaptionCredit.splitQuranCredit(" Line one \nLine two\n\(line)")
        #expect(cue.credited)
        #expect(cue.language == .en)
        #expect(cue.text == " Line one \nLine two")
        #expect(QuranCaptionCredit.url.absoluteString == "https://quran.foundation/")
    }

    @Test(arguments: [
        "المصدر: مؤسسة القرآن",
        "\u{200F}المصدر: مؤسسة القرآن",
        " \u{200F} المصدر: مؤسسة القرآن",
        "\u{200E}\u{200F}المصدر: مؤسسة القرآن",
        "بيانات القرآن مقدَّمة من مؤسسة القرآن (https://quran.foundation/\u{200E})",
    ])
    func arabicCredit(line: String) {
        let cue = QuranCaptionCredit.splitQuranCredit("آية\n\(line)")
        #expect(cue.credited)
        #expect(cue.language == .ar)
        #expect(cue.text == "آية")
    }

    @Test(arguments: [
        "", "  \n ", "Ordinary cue", "Source: Quran Foundation", "Source: Quran Foundation\nSpeech",
        "Speech\nSource: Quran Foundation in context", "Speech\nSource: Quran Foundation\n",
    ])
    func uncreditedCueStaysIntact(text: String) {
        let cue = QuranCaptionCredit.splitQuranCredit(text)
        #expect(!cue.credited)
        #expect(cue.language == nil)
        #expect(cue.text == text)
    }
}

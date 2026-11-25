import AUNCoreBridge
import Testing

@testable import AUNStudio

/// The UI-test clips are named like a creator's videos, in the app's language: screenshots show real titles.
struct SampleVideosTests {
    @Test(arguments: AppLanguage.allCases)
    func everyLanguageHasFiveDistinctRealNames(_ language: AppLanguage) {
        let names = SampleVideos.names(language: language)
        #expect(names.count == 5)
        #expect(Set(names).count == 5)
        #expect(!names.contains { $0.hasPrefix("Sample") || $0.isEmpty })
        let arabic = names.allSatisfy { name in name.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } }
        #expect(arabic == (language == .ar), "\(names)")
    }
}

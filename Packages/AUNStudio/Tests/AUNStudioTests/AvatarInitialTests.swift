import Testing

@testable import AUNStudio

/// The avatar fallback letter: Arabic names skip the «ال» article (owner, folded in from #53).
@Suite struct AvatarInitialTests {
    @Test func initialsSkipTheArabicArticle() {
        #expect(AvatarView.initial(of: "الأمة الآن") == "أ")
        #expect(AvatarView.initial(of: "حلقة التفسير") == "ح")
        #expect(AvatarView.initial(of: "ال") == "ا")
        #expect(AvatarView.initial(of: "Al Ummah Now") == "A")
        #expect(AvatarView.initial(of: "tafsir circle") == "T")
        #expect(AvatarView.initial(of: "") == "")
    }
}

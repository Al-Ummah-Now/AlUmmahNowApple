import Testing

@testable import AUNCoreBridge

struct CueEditingTests {
    private func cues() -> [CaptionCue] {
        [
            CaptionCue(id: "c1", startMs: 0, endMs: 2000, segments: [.speech("abcd efgh")]),
            CaptionCue(id: "c2", startMs: 2000, endMs: 4000, segments: [.speech("ijkl")]),
            CaptionCue(
                id: "c3", startMs: 4000, endMs: 9000,
                segments: [.quran(CaptionQuranSegment(range: "1:1:1-1:1:4", status: "review"))]),
        ]
    }

    @Test func splitSharesTimeByCharactersAndGivesAFreshID() {
        var list = cues()
        #expect(CueEditing.split(cue: 0, segment: 0, at: 4, in: &list))
        #expect(list.count == 4)
        #expect(list[0].segments == [.speech("abcd")])
        #expect(list[1].segments == [.speech("efgh")])
        #expect(list[0].endMs == list[1].startMs)
        #expect(list[0].endMs == 1000)
        #expect(Set(list.map(\.id)).count == 4)
    }

    @Test func splitRefusesAnEmptySideOrATooShortCue() {
        var list = cues()
        #expect(!CueEditing.split(cue: 0, segment: 0, at: 0, in: &list))
        #expect(!CueEditing.split(cue: 2, segment: 0, at: 0, in: &list))
        var short = [CaptionCue(id: "a", startMs: 0, endMs: 150, segments: [.speech("ab")])]
        #expect(!CueEditing.split(cue: 0, segment: 0, at: 1, in: &short))
        #expect(list == cues())
    }

    @Test func mergeJoinsSpeechWithASpaceAndKeepsQuran() {
        var list = cues()
        #expect(CueEditing.mergeWithNext(cue: 0, in: &list))
        #expect(list[0].segments == [.speech("abcd efgh ijkl")])
        #expect(list[0].endMs == 4000)
        #expect(CueEditing.mergeWithNext(cue: 0, in: &list))
        #expect(list[0].segments.count == 2)
        #expect(list[0].hasQuran)
        #expect(!CueEditing.mergeWithNext(cue: 0, in: &list))
    }

    @Test func nudgeStaysBetweenNeighboursAndKeepsTheMinimum() {
        var list = cues()
        #expect(!CueEditing.nudge(.start, by: -100, cue: 0, in: &list))
        #expect(!CueEditing.nudge(.start, by: -100, cue: 1, in: &list))
        #expect(CueEditing.nudge(.start, by: 100, cue: 1, in: &list))
        #expect(list[1].startMs == 2100)
        #expect(CueEditing.nudge(.end, by: -5000, cue: 1, in: &list))
        #expect(list[1].endMs == 2100 + CueEditing.minimumMs)
        #expect(CueEditing.nudge(.end, by: 1_000_000, cue: 2, in: &list))
        #expect(list[2].endMs == 4000 + CueEditing.maximumMs)
    }

    @Test func savingDropsBlankSpeechAndEmptyCues() {
        var list = cues()
        CueEditing.setText("  ", cue: 1, segment: 0, in: &list)
        CueEditing.setText(" new ", cue: 0, segment: 0, in: &list)
        let saved = CueEditing.forSaving(list)
        #expect(saved.map(\.id) == ["c1", "c3"])
        #expect(saved[0].segments == [.speech("new")])
    }
}

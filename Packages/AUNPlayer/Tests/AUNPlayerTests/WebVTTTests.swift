import Testing

@testable import AUNPlayer

@Suite struct WebVTTTests {
    @Test func parsesArabicCuesWithIdentifiersAndCRLF() {
        let cues = WebVTT.parse(
            "WEBVTT\r\n\r\nNOTE skip me\r\n\r\n1\r\n00:00:00.000 --> 00:00:05.000 align:start\r\nبسم <b>الله</b>\r\n")
        #expect(cues == [SubtitleCue(start: 0, end: 5, text: "بسم الله")])
    }

    @Test func parsesShortAndLongTimestamps() {
        #expect(WebVTT.timestamp("01:02.500") == 62.5)
        #expect(WebVTT.timestamp("1:00:00.000 line:0") == 3600)
        #expect(WebVTT.timestamp("nonsense") == nil)
    }

    @Test func joinsMultilineCuesAndDecodesEntities() {
        let cues = WebVTT.parse("WEBVTT\n\n00:01.000 --> 00:02.000\nA &amp; B\nC\n")
        #expect(cues.first?.text == "A & B\nC")
    }

    @Test func timelineFindsActiveCueOnly() {
        let timeline = CueTimeline([
            SubtitleCue(start: 10, end: 12, text: "b"), SubtitleCue(start: 0, end: 5, text: "a"),
        ])
        #expect(timeline.cue(at: 0)?.text == "a")
        #expect(timeline.cue(at: 5) == nil)
        #expect(timeline.cue(at: 11)?.text == "b")
        #expect(timeline.cue(at: 99) == nil)
    }

    @Test func qualityOptionsSortDescendingWithAutoFirst() {
        #expect(
            PlayerQuality.options(from: ["240p", "720p", "junk", "360p"]) == [
                .auto, .maximum(height: 720), .maximum(height: 360), .maximum(height: 240),
            ])
        #expect(PlayerQuality.maximum(height: 360).preferredMaximumResolution.height == 360)
        #expect(PlayerQuality.auto.preferredMaximumResolution == .zero)
    }
}

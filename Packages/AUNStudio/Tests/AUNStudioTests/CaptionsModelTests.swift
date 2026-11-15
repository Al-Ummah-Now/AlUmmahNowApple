import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

@MainActor
struct CaptionsModelTests {
    private func model() -> CaptionsModel {
        let model = CaptionsModel(videoID: "fixture-content-1", channelID: "fixture-channel", services: .fixtures(signedIn: true))
        model.pause = { _ in }
        return model
    }

    @Test func refreshLoadsDraftsAndMinutes() async {
        let model = model()
        await model.refresh()
        #expect(model.load == .loaded)
        #expect(model.list.drafts.map(\.language) == ["ar", "en"])
        #expect(model.list.drafts.first?.origin == .onDevice)
        #expect(model.minutes?.remaining == 216)
        #expect(!model.isWorking)
    }

    @Test func transcribingStartsAJobAndPollingFollowsIt() async {
        let model = model()
        await model.refresh()
        await model.transcribe(language: "ur")
        #expect(model.jobs.first?.language == "ur")
        #expect(model.isWorking)
        await model.cancel(model.jobs[0])
        #expect(!model.isWorking)
        #expect(model.message?.key == "studio.captions.jobs.cancelled")
    }

    @Test func publishAndDelete() async {
        let model = model()
        await model.refresh()
        let arabic = model.list.drafts[0]
        await model.publish(arabic)
        #expect(model.list.drafts[0].isPublished)
        #expect(model.message?.key == "studio.captions.published")
        await model.delete(model.list.drafts[0])
        #expect(model.list.drafts.map(\.language) == ["en"])
    }

    @Test func onDeviceTranscriptIsSent() async {
        let model = model()
        let result = await model.submit(
            OnDeviceTranscript(
                segments: [TranscriptSegment(startMs: 0, endMs: 1000, text: "x")], engine: TranscriptEngine(model: "base")),
            language: "ar")
        #expect(result == .sent)
    }

    @Test func errorsBecomeCaptionMessages() {
        #expect(CaptionsModel.message(for: CoreError.conflict("claim_pending")).key == "studio.error.captions.pending")
        #expect(CaptionsModel.message(for: CoreError.http(status: 402)).key == "studio.error.captions.minutes")
        #expect(CaptionsModel.message(for: CoreError.offline).key == "studio.error.offline")
    }
}

@MainActor
struct CaptionEditorModelTests {
    private func editor() async -> CaptionEditorModel {
        let model = CaptionEditorModel(
            videoID: "fixture-content-1", channelID: "fixture-channel", language: "ar", services: .fixtures(signedIn: true))
        await model.load()
        return model
    }

    @Test func typingInOneFieldIsOneUndoStep() async {
        let model = await editor()
        let start = Date()
        model.setText("بسم", cue: 0, segment: 0, now: start)
        model.setText("بسم الله", cue: 0, segment: 0, now: start.addingTimeInterval(0.5))
        #expect(model.save == .unsaved)
        model.undo()
        #expect(model.cues[0].segments == [.speech("بسم الله، نبدأ اليوم بتفسير سورة الكهف.")])
        #expect(!model.canUndo)
        model.redo()
        #expect(model.cues[0].segments == [.speech("بسم الله")])
    }

    @Test func splitMergeNudgeAndDeleteGoThroughCueEditing() async {
        let model = await editor()
        model.selection = "c1"
        model.split(at: 8, segment: 0)
        #expect(model.cues.count == 5)
        model.mergeWithNext()
        #expect(model.cues.count == 4)
        model.selection = "c2"
        model.nudge(.start, by: 100)
        #expect(model.cues[1].startMs == 3_300)
        model.deleteSelected()
        #expect(model.cues.count == 3)
        #expect(model.selection == "c3")
    }

    @Test func savingBumpsTheVersionAndPublishingUsesTheSavedOne() async {
        let model = await editor()
        model.setText("نص جديد", cue: 0, segment: 0)
        #expect(await model.saveNow())
        #expect(model.summary?.version == 4)
        #expect(model.save == .saved)
        #expect(await model.publish())
        #expect(model.summary?.publishedVersion == 4)
    }

    @Test func aChangedDraftIsAConflict() async {
        let services = StudioServices.fixtures(signedIn: true)
        let first = CaptionEditorModel(
            videoID: "v", channelID: "fixture-channel", language: "ar", services: services)
        let second = CaptionEditorModel(
            videoID: "v", channelID: "fixture-channel", language: "ar", services: services)
        await first.load()
        await second.load()
        first.setText("a", cue: 0, segment: 0)
        second.setText("b", cue: 0, segment: 0)
        #expect(await first.saveNow())
        #expect(!(await second.saveNow()))
        #expect(second.save == .conflict)
    }
}

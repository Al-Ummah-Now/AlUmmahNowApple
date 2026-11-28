import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

@Suite struct StudioInjectionAuditTests {
    @Test func csvWriterNeutralizesLeadingWhitespaceAndNewlineFormulas() {
        #expect(CSVWriter.field(" =CMD|' /C calc'!A0") == "' =CMD|' /C calc'!A0")
        #expect(CSVWriter.field("\n=1+1") == "\"'\n=1+1\"")
        #expect(CSVWriter.field("  +SUM(A1:A2)") == "'  +SUM(A1:A2)")
        #expect(CSVWriter.field("  -evil") == "'  -evil")
        #expect(CSVWriter.field("-42.5") == "-42.5")
    }

    @Test func renditionUploaderBlocksPathTraversalOutsideRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "rend-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = StubRenditionsService()
        let uploader = RenditionUploader(
            service: service, videoID: "v1", channelID: "c1", root: root, rungs: ["720p"],
            files: [StagedFile(path: "../secret.txt", bytes: 5)], encoder: "test")
        let outcome = await uploader.run()
        #expect(outcome == .failed(String(describing: CoreError.invalid("invalid_path"))))
    }
}

private struct StubRenditionsService: RenditionsServicing {
    func createRenditions(
        videoID: String, rungs: [String], files: [StagedFile], encoder: String, channelID: String?
    ) async throws -> RenditionStaging {
        RenditionStaging(stagingID: "s1", maxFileBytes: nil)
    }

    func putRenditionFile(
        videoID: String, stagingID: String, file: StagedFile, bytes: Data, channelID: String?
    ) async throws {}

    func completeRenditions(videoID: String, stagingID: String, channelID: String?) async throws {}
    func cancelRenditions(videoID: String, stagingID: String, channelID: String?) async throws {}
}

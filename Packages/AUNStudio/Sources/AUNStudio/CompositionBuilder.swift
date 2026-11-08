import AUNCoreBridge
import AVFoundation

public enum CompositionError: Error, Sendable { case empty, noVideo(URL), exportFailed(String) }

/// Turns the edit list into an AVFoundation composition, used by preview and export on Mac and iPhone.
public enum CompositionBuilder {
    public static func build(_ list: EditDecisionList) async throws -> AVMutableComposition {
        guard !list.clips.isEmpty else { throw CompositionError.empty }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CompositionError.empty }
        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        for clip in list.clips {
            let asset = AVURLAsset(url: clip.source)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw CompositionError.noVideo(clip.source)
            }
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600))
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                if audioTrack == nil {
                    audioTrack = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try audioTrack?.insertTimeRange(range, of: sourceAudio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        return composition
    }

    public static func export(_ list: EditDecisionList, to output: URL) async throws {
        let composition = try await build(list)
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CompositionError.exportFailed("no session")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        nonisolated(unsafe) let exporting = session
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporting.exportAsynchronously {
                if exporting.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CompositionError.exportFailed(String(describing: exporting.error)))
                }
            }
        }
    }
}

import AUNCoreBridge
import AVFoundation

/// Builds an AVFoundation composition from Core's flattened timeline (`edl_flatten_json`): one composition track per
/// timeline track, each clip inserted at its timeline start, scaled for its speed, with its volume in the audio mix.
public enum TimelineComposer {
    public struct Built: @unchecked Sendable {
        public let composition: AVMutableComposition
        public let audioMix: AVMutableAudioMix?
    }

    static func time(_ ms: Int) -> CMTime { CMTime(value: CMTimeValue(ms), timescale: 1000) }

    // swiftlint:disable:next cyclomatic_complexity
    public static func build(_ timeline: FlattenedTimeline) async throws -> Built {
        let composition = AVMutableComposition()
        var mixParameters: [AVMutableAudioMixInputParameters] = []
        var inserted = false
        var videoTransformSet = false
        for track in timeline.tracks where !track.clips.isEmpty {
            let isVideo = track.kind == "video"
            // A video track's sound goes on its own audio track, so a muted track can drop it.
            let videoTrack =
                isVideo ? composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
            var audioTrack: AVMutableCompositionTrack?
            var audioParameters: AVMutableAudioMixInputParameters?
            for clip in track.clips {
                let asset = AVURLAsset(url: URL(fileURLWithPath: clip.path))
                let source = CMTimeRange(start: time(clip.inMs), end: time(clip.outMs))
                let at = time(clip.timelineStartMs)
                let target = time(clip.timelineDurationMs)
                if let videoTrack {
                    guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                        throw CompositionError.noVideo(asset.url)
                    }
                    try videoTrack.insertTimeRange(source, of: sourceVideo, at: at)
                    if clip.speed != 1 {
                        videoTrack.scaleTimeRange(CMTimeRange(start: at, duration: source.duration), toDuration: target)
                    }
                    if !videoTransformSet {
                        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
                        videoTransformSet = true
                    }
                    inserted = true
                }
                guard !track.muted, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                if audioTrack == nil {
                    audioTrack = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    audioParameters = audioTrack.map { AVMutableAudioMixInputParameters(track: $0) }
                }
                guard let audioTrack else { continue }
                try audioTrack.insertTimeRange(source, of: sourceAudio, at: at)
                if clip.speed != 1 {
                    audioTrack.scaleTimeRange(CMTimeRange(start: at, duration: source.duration), toDuration: target)
                }
                audioParameters?.setVolume(Float(max(0, min(clip.volume, 2))), at: at)
                inserted = true
            }
            if let audioParameters { mixParameters.append(audioParameters) }
        }
        guard inserted else { throw CompositionError.empty }
        let mix: AVMutableAudioMix? =
            mixParameters.isEmpty
            ? nil
            : {
                let mix = AVMutableAudioMix()
                mix.inputParameters = mixParameters
                return mix
            }()
        return Built(composition: composition, audioMix: mix)
    }

    /// Renders the timeline to an MP4 the normal upload can take.
    public static func export(
        _ timeline: FlattenedTimeline, to output: URL, videoComposition: AVVideoComposition? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let built = try await build(timeline)
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw CompositionError.exportFailed("no session") }
        session.outputURL = output
        session.outputFileType = .mp4
        session.audioMix = built.audioMix
        session.videoComposition = videoComposition
        nonisolated(unsafe) let exporting = session
        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(exporting.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { ticker.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exporting.exportAsynchronously {
                    switch exporting.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    default: continuation.resume(throwing: CompositionError.exportFailed(String(describing: exporting.error)))
                    }
                }
            }
        } onCancel: {
            exporting.cancelExport()
        }
        progress(1)
    }
}

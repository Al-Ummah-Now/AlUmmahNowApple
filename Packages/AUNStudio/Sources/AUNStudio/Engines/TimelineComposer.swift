import AUNCoreBridge
import AVFoundation
import CoreImage

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

    /// The frame size the composition shows (the first video's display size).
    public static func renderSize(of built: Built) async throws -> CGSize? {
        guard let track = built.composition.tracks(withMediaType: .video).first else { return nil }
        let size = track.naturalSize.applying(track.preferredTransform)
        return size.width == 0 || size.height == 0 ? nil : CGSize(width: abs(size.width), height: abs(size.height))
    }

    /// A title image and when it is on screen, for the export's frame handler.
    private struct TitleFrame: @unchecked Sendable {
        let start: Double
        let end: Double
        let image: CIImage
    }

    /// A video composition that draws the timeline's titles over each frame with the images the preview shows, each
    /// visible from its start for its length. Core Image applies the clips' rotation. Nil when there are no titles or
    /// no picture.
    public static func titleComposition(
        _ built: Built, titles: [FlattenedTimeline.Title], brand: TitleBrand, fps: Double = 30
    ) async throws -> AVVideoComposition? {
        guard !titles.isEmpty, let size = try await renderSize(of: built) else { return nil }
        let frames = titles.compactMap { title -> TitleFrame? in
            guard let image = TitleRenderer.image(title, brand: brand, canvas: size) else { return nil }
            return TitleFrame(
                start: Double(title.startMs) / 1000, end: Double(title.endMs) / 1000, image: CIImage(cgImage: image))
        }
        guard !frames.isEmpty else { return nil }
        let composition = try await AVMutableVideoComposition.videoComposition(with: built.composition) { request in
            let seconds = request.compositionTime.seconds
            let source = request.sourceImage
            var output = source
            for frame in frames where seconds >= frame.start && seconds < frame.end {
                // The title image is the frame's size, so it lines up whatever the source's origin.
                output = frame.image
                    .transformed(by: CGAffineTransform(translationX: source.extent.minX, y: source.extent.minY))
                    .composited(over: output)
            }
            request.finish(with: output.cropped(to: source.extent), context: nil)
        }
        composition.renderSize = size
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, min(120, fps.rounded()))))
        return composition
    }

    /// Renders the timeline to an MP4 the normal upload can take, with its titles drawn in.
    public static func export(
        _ timeline: FlattenedTimeline, to output: URL, videoComposition: AVVideoComposition? = nil,
        brand: TitleBrand = TitleBrand(), fps: Double = 30, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let built = try await build(timeline)
        var videoComposition = videoComposition
        if videoComposition == nil {
            videoComposition = try await titleComposition(built, titles: timeline.titles, brand: brand, fps: fps)
        }
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

import AUNCoreBridge
import AVFoundation
import Foundation

/// Small real MP4 files for UI tests (`-AUNSampleVideos <count>`), so a test never drives the system pickers.
public enum SampleVideos {
    public static func requestedCount(defaults: UserDefaults = .standard) -> Int {
        max(0, min(5, defaults.integer(forKey: "AUNSampleVideos")))
    }

    /// Writes `count` one-second H.264 clips into the app's upload folder.
    public static func make(count: Int) async -> [URL] {
        var urls: [URL] = []
        for index in 0..<count {
            let url = UploadStore.filesDirectory.appending(path: "sample-\(UUID().uuidString.prefix(8))/Sample \(index + 1).mp4")
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await write(url, shade: UInt8(40 + index * 50))
                urls.append(url)
            } catch {
                AUNLog.studio.error("Sample video failed: \(error)")
            }
        }
        return urls
    }

    private static func write(_ url: URL, shade: UInt8) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(shade) &+ Int32(frame), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

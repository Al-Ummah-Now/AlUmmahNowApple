import AUNCoreBridge
import Foundation

/// Pre-encoded renditions (E19 19.3, D11): every rung of the server's ladder encoded on this computer, packaged as
/// fMP4 HLS by Core and sent with `RenditionUploader`. Opt-in at upload and never in the upload's way: it returns an
/// outcome instead of throwing, and anything but `.ready` means the server encodes the video as usual.
public struct PreEncoder: Sendable {
    public enum Phase: Hashable, Sendable {
        case inspecting
        /// `index` counts from 1.
        case encoding(rung: String, index: Int, count: Int)
        case uploading
    }

    public struct Status: Hashable, Sendable {
        public var phase: Phase
        /// The whole run, 0…1.
        public var fraction: Double
    }

    /// Progress of one rung's encode, 0…1.
    public typealias EncodeProgress = @Sendable (Double) async -> Void
    /// Encodes one rung of a source (`source`, `rung`, `output`, progress) to a progressive MP4.
    public typealias Encode = @Sendable (URL, HLSRung, URL, @escaping EncodeProgress) async throws -> Void

    let packaging: any RenditionPackaging
    let renditions: any RenditionsServicing
    let workRoot: URL
    var inspect: @Sendable (URL) async throws -> SourceVideoInfo = { try await SourceVideoInfo.inspect($0) }
    var encode: Encode = { source, rung, output, progress in
        try await RungEncoder().encode(source: source, rung: rung, to: output, progress: progress)
    }
    /// Lets tests skip the uploader's waits between retries.
    var uploaderPause: (@Sendable (Duration) async throws -> Void)?

    /// The part of the whole run that is encoding; the rest is sending.
    static let encodeShare = 0.85

    public init(packaging: any RenditionPackaging, renditions: any RenditionsServicing, workRoot: URL) {
        self.packaging = packaging
        self.renditions = renditions
        self.workRoot = workRoot
    }

    /// Where Studio keeps a run's rung files until they are sent; removed after every run.
    public static var defaultWorkRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "studio-renditions", directoryHint: .isDirectory)
    }

    public func run(
        source: URL, videoID: String, channelID: String?, encoder: String,
        status: @escaping @Sendable (Status) async -> Void = { _ in }
    ) async -> RenditionUploader.Outcome {
        let work = workRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appending(path: "rungs", directoryHint: .isDirectory)
        do {
            await status(Status(phase: .inspecting, fraction: 0))
            let info = try await inspect(source)
            let ladder = packaging.ladder(width: info.codedWidth, height: info.codedHeight, rotation: info.rotation)
            guard !ladder.isEmpty else { return .failed("no rungs for \(info.codedWidth)x\(info.codedHeight)") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (offset, rung) in ladder.enumerated() {
                try Task.checkCancellation()
                guard SafeInput.isSafeFileName(rung.name) else { throw CoreError.invalid("rung_name") }
                let share = Self.encodeShare / Double(ladder.count)
                let base = share * Double(offset)
                let phase = Phase.encoding(rung: rung.name, index: offset + 1, count: ladder.count)
                await status(Status(phase: phase, fraction: base))
                let mp4 = work.appending(path: "\(rung.name).mp4")
                try await encode(source, rung, mp4) { fraction in
                    // Packaging is quick next to encoding: encoding takes 95 % of the rung's share.
                    await status(Status(phase: phase, fraction: base + share * 0.95 * fraction))
                }
                _ = try await packaging.package(
                    mp4: mp4, outputDirectory: root.appending(path: rung.name, directoryHint: .isDirectory),
                    segmentSeconds: rung.segmentSeconds)
                try? FileManager.default.removeItem(at: mp4)
            }
            let rungs = ladder.map(\.name)
            let files = try packaging.files(root: root, rungs: rungs)
            await status(Status(phase: .uploading, fraction: Self.encodeShare))
            var uploader = RenditionUploader(
                service: renditions, videoID: videoID, channelID: channelID, root: root, rungs: rungs, files: files,
                encoder: encoder)
            if let uploaderPause { uploader.pause = uploaderPause }
            return await uploader.run { progress in
                await status(
                    Status(phase: .uploading, fraction: Self.encodeShare + (1 - Self.encodeShare) * progress.fraction))
            }
        } catch is CancellationError {
            return .cancelled
        } catch CoreError.cancelled {
            return .cancelled
        } catch {
            AUNLog.studio.error("Pre-encoding failed; the server encodes instead: \(error)")
            return .failed(String(describing: error))
        }
    }

    /// What the server records as the encoder, e.g. "Al Ummah Now Studio 1.2 (macOS VideoToolbox)".
    public static func encoderName(bundle: Bundle = .main) -> String {
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Al Ummah Now Studio \(version) (VideoToolbox)"
    }
}

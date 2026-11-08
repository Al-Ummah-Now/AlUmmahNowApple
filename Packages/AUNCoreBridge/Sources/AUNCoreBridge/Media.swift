import Foundation

public enum VideoCodec: String, CaseIterable, Sendable { case h264, hevc }

public struct EncodePreset: Hashable, Sendable {
    public var name: String
    public var codec: VideoCodec
    public var maxHeight: Int
    public var averageBitRate: Int

    public init(name: String, codec: VideoCodec, maxHeight: Int, averageBitRate: Int) {
        self.name = name
        self.codec = codec
        self.maxHeight = maxHeight
        self.averageBitRate = averageBitRate
    }

    public static let lecture = EncodePreset(name: "lecture", codec: .hevc, maxHeight: 1080, averageBitRate: 5_000_000)
}

public struct EncodePlan: Hashable, Sendable {
    public var source: URL
    public var destination: URL
    public var preset: EncodePreset

    public init(source: URL, destination: URL, preset: EncodePreset) {
        self.source = source
        self.destination = destination
        self.preset = preset
    }
}

/// Turns a source and preset into a job. `aun-media` replaces the native planner; VideoToolbox still executes.
public protocol EncodePlanning: Sendable {
    func plan(source: URL, preset: EncodePreset, outputDirectory: URL) -> EncodePlan
}

public struct NativeEncodePlanner: EncodePlanning {
    public init() {}

    public func plan(source: URL, preset: EncodePreset, outputDirectory: URL) -> EncodePlan {
        let name = source.deletingPathExtension().lastPathComponent + "-\(preset.name).mp4"
        return EncodePlan(source: source, destination: outputDirectory.appending(path: name), preset: preset)
    }
}

public struct EditClip: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var source: URL
    public var sourceStart: Double
    public var duration: Double

    public init(id: UUID = UUID(), source: URL, sourceStart: Double = 0, duration: Double) {
        self.id = id
        self.source = source
        self.sourceStart = sourceStart
        self.duration = duration
    }
}

/// Interim edit model, replaced by the versioned EDL from `aun-media` (Epic 30.5). One video track for now.
public struct EditDecisionList: Hashable, Sendable {
    public private(set) var clips: [EditClip]
    public static let minimumClipDuration = 0.1

    public init(clips: [EditClip] = []) { self.clips = clips }

    public var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    public mutating func append(_ clip: EditClip) { clips.append(clip) }

    /// The clip under a timeline position and the position within it.
    public func locate(_ time: Double) -> (index: Int, offset: Double)? {
        var start = 0.0
        for (index, clip) in clips.enumerated() {
            if time >= start, time < start + clip.duration { return (index, time - start) }
            start += clip.duration
        }
        return nil
    }

    /// Splits at a timeline position. Ignored when either side would be too short.
    public mutating func split(at time: Double) {
        guard let (index, offset) = locate(time), offset >= Self.minimumClipDuration,
            clips[index].duration - offset >= Self.minimumClipDuration
        else { return }
        let clip = clips[index]
        var head = clip
        head.duration = offset
        let tail = EditClip(source: clip.source, sourceStart: clip.sourceStart + offset, duration: clip.duration - offset)
        clips[index] = head
        clips.insert(tail, at: index + 1)
    }

    /// Removes a clip and closes the gap.
    public mutating func rippleDelete(id: UUID) { clips.removeAll { $0.id == id } }

    public mutating func move(id: UUID, by delta: Int) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + delta), clips.count - 1)
        let clip = clips.remove(at: index)
        clips.insert(clip, at: target)
    }

    /// Trims a clip's ends within its source, keeping the minimum duration.
    public mutating func trim(id: UUID, start: Double, end: Double) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips[index]
        let safeStart = min(max(0, start), clip.duration - Self.minimumClipDuration)
        let safeEnd = min(max(safeStart + Self.minimumClipDuration, end), clip.duration)
        clips[index].sourceStart = clip.sourceStart + safeStart
        clips[index].duration = safeEnd - safeStart
    }
}

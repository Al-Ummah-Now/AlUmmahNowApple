import Foundation

public struct SubtitleCue: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Parses the sidecar WebVTT the API serves. Styling tags and cue settings are dropped.
public enum WebVTT {
    public static func parse(_ source: String) -> [SubtitleCue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }), timingIndex <= 1 else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = timestamp(parts[0]), let end = timestamp(parts[1]) else { continue }
            let text = stripTags(lines[(timingIndex + 1)...].joined(separator: "\n"))
            if !text.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func timestamp(_ raw: String) -> Double? {
        guard let token = raw.split(whereSeparator: \.isWhitespace).first else { return nil }
        let fields = token.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        guard (2...3).contains(fields.count) else { return nil }
        return fields.reduce(0) { $0 * 60 + $1 }
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Fast lookup of the cue active at a playback time.
public struct CueTimeline: Sendable {
    private let cues: [SubtitleCue]

    public init(_ cues: [SubtitleCue]) { self.cues = cues.sorted { $0.start < $1.start } }

    public func cue(at time: Double) -> SubtitleCue? {
        var low = 0
        var high = cues.count - 1
        var candidate: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let candidate, time < cues[candidate].end else { return nil }
        return cues[candidate]
    }
}

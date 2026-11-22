import SwiftUI

/// Items in reading order that wrap onto a new line instead of running off the edge: chips and tiles that never get
/// cut, with the same rule in English and Arabic (SwiftUI mirrors the placement right to left).
public struct FlowLayout: Layout {
    private let spacing: CGFloat
    private let lineSpacing: CGFloat
    private let balanced: Bool

    /// `balanced` keeps the number of lines but spreads the items evenly over them (five chips on two lines: 3 + 2),
    /// so English and Arabic, whose words differ in width, wrap at the same item when they need the same lines.
    public init(spacing: CGFloat = FanousScale.spacingSm, lineSpacing: CGFloat? = nil, balanced: Bool = false) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing
        self.balanced = balanced
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(for: subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2), anchor: .topLeading,
                    proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(for subviews: Subviews, width: CGFloat) -> [Line] {
        let greedy = greedyLines(for: subviews, width: width)
        guard balanced, greedy.count > 1 else { return greedy }
        let perLine = Int((Double(subviews.count) / Double(greedy.count)).rounded(.up))
        var lines: [Line] = []
        for start in stride(from: 0, to: subviews.count, by: perLine) {
            var line = Line()
            for index in start..<min(start + perLine, subviews.count) {
                let size = subviews[index].sizeThatFits(.unspecified)
                let itemWidth = min(size.width, width)
                line.width = line.indices.isEmpty ? itemWidth : line.width + spacing + itemWidth
                line.height = max(line.height, size.height)
                line.indices.append(index)
            }
            // An even line that would run off the edge: keep the plain wrapping.
            if line.width > width { return greedy }
            lines.append(line)
        }
        return lines
    }

    private func greedyLines(for subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            let needed = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            if !current.indices.isEmpty, needed > width {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}

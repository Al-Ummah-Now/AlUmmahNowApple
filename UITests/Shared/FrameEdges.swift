import XCTest

/// The review rule "every frame ends on whole content", checked on the accessibility tree of the frame just taken.
/// A frame has a top edge (the bottom of the navigation bar or window toolbar) and a bottom edge (the top of the tab
/// bar, else the bottom of the screen or window). No text may cross either edge, and the last line above the bottom
/// edge keeps a clear gap. A video card may run past the bottom of an iPhone or iPad screen or under the tab bar, as a
/// scrolling page does, but never through the title on its art or the title and meta under it. On the Mac the window
/// bottom is a crop, so a video card is in the frame whole or not at all.
enum FrameEdges {
    /// The clear gap above the bottom edge, in points.
    static let gap: CGFloat = 8

    struct Reading {
        var cuts: [String] = []
        var layout: [String] = []
    }

    @MainActor
    static func read(_ app: XCUIApplication) -> Reading {
        #if os(tvOS)
            return Reading()
        #else
            // The frame is the front window on the Mac (StoreScreenshot captures only it), the screen elsewhere.
            #if os(macOS)
                let source: XCUIElement = app.windows.firstMatch
                let crop = true
            #else
                let source: XCUIElement = app
                let crop = false
            #endif
            guard let root = try? source.snapshot() else { return Reading(cuts: [], layout: ["no snapshot"]) }
            let window = root.frame
            var top = window.minY
            var bottom = window.maxY
            var items: [XCUIElementSnapshot] = []
            collect(root, into: &items, top: &top, bottom: &bottom, window: window)
            var reading = Reading()
            reading.layout.append("window \(text(window)) top \(Int(top)) bottom \(Int(bottom))")
            for item in items {
                let frame = item.frame
                guard frame.width >= 1, frame.height >= 1, frame.maxX > window.minX + 1, frame.minX < window.maxX - 1
                else { continue }
                // The layout lists the page beyond the edges too: what an edge would cut at another height or offset.
                let what = "\(item.elementType.rawValue) \(item.identifier.isEmpty ? "-" : item.identifier) «\(item.label)»"
                reading.layout.append("\(text(frame)) \(what)")
                guard frame.maxY > top, frame.minY < bottom else { continue }
                for edge in crossings(item, top: top, bottom: bottom, crop: crop) {
                    reading.cuts.append("\(edge) edge: \(what) at \(text(frame))")
                }
            }
            return reading
        #endif
    }

    /// Which edges the element is cut by.
    private static func crossings(_ item: XCUIElementSnapshot, top: CGFloat, bottom: CGFloat, crop: Bool) -> [String] {
        let frame = item.frame
        var edges: [String] = []
        if isVideoCard(item) {
            // Text on a card: the title drawn on the art (measured on the fixture art: its glyphs, Arabic marks
            // included, sit between 5% and 33% of the art's height), the duration badge at the art's bottom, and the
            // title and meta under the art. Elsewhere the art is picture only, which may pass under a bar.
            let art = min(frame.width * 9 / 16, frame.height)
            let bands = [
                (frame.minY + art * 0.05, frame.minY + art * 0.33), (frame.minY + art * 0.85, frame.maxY),
            ]
            if bands.contains(where: { $0.0 < top && $0.1 > top + 3 }) { edges.append("top") }
            if crop {
                if frame.minY < bottom, frame.maxY > bottom - gap { edges.append("bottom") }
            } else if bands.contains(where: { $0.0 < bottom && $0.1 > bottom - gap }) {
                edges.append("bottom")
            }
            return edges
        }
        // A tall button that is not a card is a picture (the player): only its own text would count, and it has none.
        if item.elementType == .button, frame.height > 60 { return edges }
        // A row whose lines are their own elements is checked line by line, through them.
        if item.children.contains(where: { isText($0.elementType) }) { return edges }
        // A line box takes in its leading, about a fifth of one line's height (at most 6 points), and the leading past
        // an edge shows no glyph: a line wholly under the tab bar but for its leading is hidden, not cut.
        let leading = max(3, min(frame.height, 30) * 0.2)
        if frame.minY < top, frame.maxY > top + 3 { edges.append("top") }
        if frame.minY < bottom - leading, frame.maxY > bottom - gap { edges.append("bottom") }
        return edges
    }

    #if !os(tvOS)
        /// Text-bearing elements of the page, and the edges the bars set. Bars (and everything in them) are not page
        /// content: a navigation bar or toolbar at the top sets the top edge, a tab bar at the bottom the bottom edge.
        private static func collect(
            _ node: XCUIElementSnapshot, into items: inout [XCUIElementSnapshot], top: inout CGFloat,
            bottom: inout CGFloat, window: CGRect
        ) {
            switch node.elementType {
            case .navigationBar, .toolbar:
                // Only a bar on screen at the top: other tabs keep their (hidden) navigation bars in the tree.
                let bar = node.frame
                if bar.minY < window.minY + 120, bar.maxY < window.midY, bar.height > 0 { top = max(top, bar.maxY) }
                return
            case .tabBar:
                if node.frame.minY > window.midY { bottom = min(bottom, node.frame.minY) }
                return
            case .statusBar, .menuBar, .scrollBar:
                return
            case let type where isText(type):
                items.append(node)
                if isVideoCard(node) { return }
            default:
                break
            }
            for child in node.children { collect(child, into: &items, top: &top, bottom: &bottom, window: window) }
        }
    #endif

    /// Elements that draw text of their own.
    private static func isText(_ type: XCUIElement.ElementType) -> Bool {
        [.staticText, .button, .link, .textField, .searchField, .checkBox, .popUpButton, .slider].contains(type)
    }

    /// A video card (a rail's or Up next's: art with its title on it, then the title and meta under it), or the home
    /// hero's art.
    private static func isVideoCard(_ node: XCUIElementSnapshot) -> Bool {
        node.identifier.hasPrefix("video-card-") || node.identifier.hasPrefix("up-next-")
            || (node.identifier == "home-hero" && node.elementType == .button)
    }

    private static func text(_ rect: CGRect) -> String {
        "y \(Int(rect.minY.rounded()))–\(Int(rect.maxY.rounded())) x \(Int(rect.minX.rounded()))–\(Int(rect.maxX.rounded()))"
    }
}

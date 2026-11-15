import AUNCoreBridge
import Foundation

/// What the brand kit gives titles (E19 19.9): colours, the lower third's shape and side, and the logo. The EDL keeps
/// each title's colours and size; the shape, side and logo come from the kit when the title is drawn.
public struct TitleBrand: Hashable, Sendable {
    public var kit: BrandKit
    /// The logo image's bytes (PNG/JPEG/…), when the kit has one and it loaded.
    public var logo: Data?
    /// True when the channel's kit loaded; false means the server's default colours.
    public var fromKit: Bool

    public init(kit: BrandKit = BrandKit(), logo: Data? = nil, fromKit: Bool = false) {
        self.kit = kit
        self.logo = logo
        self.fromKit = fromKit
    }

    /// The platform's interface font (SF Pro, with SF Arabic for Arabic). Brand kits have no font yet.
    public static let systemFont = "system"
    /// Sizes on a 1080-line frame.
    public static let lowerThirdSizePt = 44.0
    public static let titleSizePt = 72.0

    /// A new title's style from the kit: kit text colour (or the kit colour that reads best on the box), and for lower
    /// thirds the kit's bar or box behind the text.
    public func style(for position: FlattenedTimeline.TitleStyle.Position) -> FlattenedTimeline.TitleStyle {
        let colors = kit.colors
        let background: String? =
            switch (position, kit.lowerThird.style) {
            case (.lowerThird, .bar): colors.secondary
            case (.lowerThird, .box): colors.primary
            default: nil
            }
        let color = background.map { Self.readable(on: $0, candidates: [colors.text, colors.secondary, colors.background]) }
        return FlattenedTimeline.TitleStyle(
            fontFamily: Self.systemFont, sizePt: position == .lowerThird ? Self.lowerThirdSizePt : Self.titleSizePt,
            color: color ?? colors.text, background: background, position: position)
    }

    /// The candidate with the highest WCAG contrast against `background`.
    static func readable(on background: String, candidates: [String]) -> String {
        candidates.filter(BrandKit.isValidColor).max { contrast($0, background) < contrast($1, background) } ?? "#ffffff"
    }

    static func contrast(_ a: String, _ b: String) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ hex: String) -> Double {
        guard let rgb = rgb(hex) else { return 0 }
        func channel(_ value: Double) -> Double {
            value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.r) + 0.7152 * channel(rgb.g) + 0.0722 * channel(rgb.b)
    }

    /// `#rrggbb` → components 0…1.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard BrandKit.isValidColor(hex), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

extension FlattenedTimeline.Title {
    /// The non-empty lines, Arabic first, then English, then any other locale: the same order on every app.
    public var lines: [(locale: String, text: String)] {
        let rank = ["ar": 0, "en": 1]
        return text.compactMap { key, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (key, trimmed)
        }
        .sorted { (rank[$0.locale] ?? 2, $0.locale) < (rank[$1.locale] ?? 2, $1.locale) }
    }

    /// The EDL `TitleClip` JSON object (`addTitle`/`setTitle`).
    var edlObject: [String: Any] {
        var style: [String: Any] = [
            "fontFamily": self.style.fontFamily, "sizePt": self.style.sizePt, "color": self.style.color,
            "position": self.style.position.rawValue,
        ]
        if let background = self.style.background { style["background"] = background }
        return ["id": titleID, "startMs": startMs, "durationMs": durationMs, "text": text, "style": style]
    }
}

/// Titles and lower thirds (E19 19.5): added, reworded, moved, retimed, restyled and removed through Core's
/// `addTitle`/`setTitle`/`removeTitle`, each one undo step.
extension EditorModel {
    /// The title track the editor creates on the first title.
    public nonisolated static let titleTrack = "t1"
    /// A new title's length, and the shortest a title gets.
    public nonisolated static let titleDurationMs = 4_000
    public nonisolated static let minTitleMs = 500

    public var titles: [FlattenedTimeline.Title] { timeline.titles }
    public var selectedTitle: FlattenedTimeline.Title? { titles.first { $0.titleID == selection } }

    /// Titles on screen at `ms`.
    public func titles(at ms: Int) -> [FlattenedTimeline.Title] {
        titles.filter { ms >= $0.startMs && ms < $0.endMs }
    }

    /// Adds a title at the playhead, styled from the kit. `text` maps locale → text; empty lines are dropped.
    public func addTitle(position: FlattenedTimeline.TitleStyle.Position, text: [String: String], brand: TitleBrand) {
        let text = text.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !isEmpty else { return }
        guard !text.isEmpty else { return fail("studio.editor.titles.error.text") }
        let end = timeline.durationMs
        let start = max(0, min(playheadMs, end - Self.minTitleMs))
        let title = FlattenedTimeline.Title(
            titleID: "t-\(makeID())", trackID: "", startMs: start,
            durationMs: max(Self.minTitleMs, min(Self.titleDurationMs, end - start)), text: text,
            style: brand.style(for: position))
        do {
            let (withTrack, trackID) = try Self.addingTitleTrack(to: project)
            let op: [String: Any] = ["op": "addTitle", "trackId": trackID, "title": title.edlObject]
            commit(try edlApply(project: withTrack, op: op))
            selection = title.titleID
        } catch {
            AUNLog.studio.info("Adding a title refused: \(error)")
            fail("studio.editor.error.refused")
        }
    }

    /// Replaces a title (same id) through `setTitle`.
    @discardableResult
    public func setTitle(_ title: FlattenedTimeline.Title, refused: String = "studio.editor.error.refused") -> Bool {
        apply(["op": "setTitle", "title": title.edlObject], refused: refused)
    }

    public func moveTitle(_ id: String, toMs startMs: Int) {
        guard var title = titles.first(where: { $0.titleID == id }) else { return }
        title.startMs = max(0, startMs)
        guard title.startMs != titles.first(where: { $0.titleID == id })?.startMs else { return }
        setTitle(title)
    }

    /// Sets a title's start and length (at least `minTitleMs`).
    public func retimeTitle(_ id: String, startMs: Int, durationMs: Int) {
        guard var title = titles.first(where: { $0.titleID == id }) else { return }
        title.startMs = max(0, startMs)
        title.durationMs = max(Self.minTitleMs, durationMs)
        setTitle(title)
    }

    /// Lengthens (positive) or shortens a title from its end.
    public func resizeTitle(_ id: String, by deltaMs: Int) {
        guard let title = titles.first(where: { $0.titleID == id }) else { return }
        retimeTitle(id, startMs: title.startMs, durationMs: title.durationMs + deltaMs)
    }

    /// New wording; a title needs at least one line.
    public func setTitleText(_ id: String, text: [String: String]) {
        guard var title = titles.first(where: { $0.titleID == id }) else { return }
        let text = text.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !text.isEmpty else { return fail("studio.editor.titles.error.text") }
        guard text != title.text else { return }
        title.text = text
        setTitle(title)
    }

    /// Moves a title to the top, the centre or the lower third, restyled from the kit for that place.
    public func setTitlePosition(_ id: String, _ position: FlattenedTimeline.TitleStyle.Position, brand: TitleBrand) {
        guard var title = titles.first(where: { $0.titleID == id }), title.style.position != position else { return }
        title.style = brand.style(for: position)
        setTitle(title)
    }

    /// Restyles a title from the current kit (after the kit changed).
    public func applyBrand(_ id: String, brand: TitleBrand) {
        guard var title = titles.first(where: { $0.titleID == id }) else { return }
        let style = brand.style(for: title.style.position)
        guard style != title.style else { return }
        title.style = style
        setTitle(title)
    }

    public func removeTitle(_ id: String) {
        if apply(["op": "removeTitle", "titleId": id], refused: "studio.editor.error.refused"), selection == id {
            selection = nil
        }
    }

    // MARK: Internals

    func edlApply(project: String, op: [String: Any]) throws -> String {
        try edl.apply(project: project, op: Self.json(op))
    }

    /// The project's first title track, adding one to the JSON when it has none (Core has no op for tracks).
    nonisolated static func addingTitleTrack(to project: String) throws -> (project: String, trackID: String) {
        guard var object = object(project) else { throw CoreError.decoding }
        var tracks = (object["tracks"] as? [[String: Any]]) ?? []
        if let existing = tracks.first(where: { $0["kind"] as? String == "title" })?["id"] as? String {
            return (project, existing)
        }
        tracks.append(["id": titleTrack, "kind": "title"])
        object["tracks"] = tracks
        return (try json(object), titleTrack)
    }
}

import AUNCoreBridge
import Foundation

/// What the brand kit gives titles (E19 19.9): colours for new titles, and when drawing, the lower third's template
/// (bar, box or minimal), its side and the logo. Mirrors Desktop's `TitleTemplates` and `TitleDecor`, so the same
/// project gets the same titles in every app.
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

    /// A family with Arabic and Latin. Brand kits have no font yet; where it isn't installed each app uses its own
    /// interface font (SF Pro and SF Arabic on Apple).
    public static let fontFamily = "Noto Sans Arabic"
    public static let titleSizePt = 44.0
    public static let lowerThirdSizePt = 28.0

    /// A new title's style from the kit: the kit's text colour, and for lower thirds the bar (secondary colour) or box
    /// (primary colour) behind it; minimal has none.
    public func style(for kind: EditorTitleKind) -> FlattenedTimeline.TitleStyle {
        let colors = kit.colors
        func valid(_ value: String, _ fallback: String) -> String {
            BrandKit.isValidColor(value) ? value.lowercased() : fallback
        }
        let text = valid(colors.text, BrandKit.defaultColors.text)
        guard kind == .lowerThird else {
            return .init(fontFamily: Self.fontFamily, sizePt: Self.titleSizePt, color: text, position: .center)
        }
        let background: String? =
            switch kit.lowerThird.style {
            case .box: valid(colors.primary, BrandKit.defaultColors.primary)
            case .minimal: nil
            case .bar: valid(colors.secondary, BrandKit.defaultColors.secondary)
            }
        return .init(
            fontFamily: Self.fontFamily, sizePt: Self.lowerThirdSizePt, color: text, background: background,
            position: .lowerThird)
    }

    /// `#rrggbb` → components 0…1.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard BrandKit.isValidColor(hex), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

/// A centred title, or a lower third (a name or caption in the bottom third of the picture).
public enum EditorTitleKind: String, CaseIterable, Sendable {
    case title, lowerThird

    public init(_ style: FlattenedTimeline.TitleStyle) { self = style.position == .center ? .title : .lowerThird }
}

extension FlattenedTimeline.Title {
    /// The non-empty lines, Arabic first, then English, then any other locale: what the picture shows, top to bottom,
    /// on every app.
    public var lines: [(locale: String, text: String)] {
        let rank = ["ar": 0, "en": 1]
        return text.compactMap { key, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (key, trimmed)
        }
        .sorted { (rank[$0.locale] ?? 2, $0.locale) < (rank[$1.locale] ?? 2, $1.locale) }
    }

    public var kind: EditorTitleKind { EditorTitleKind(style) }

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
/// `addTitle`/`setTitle`/`removeTitle`, each one undo step. Same rules as Desktop: titles never overlap, are at least
/// 0.1 s long and stay inside the video.
extension EditorModel {
    /// The title track the editor creates when the project has none (same id as Desktop).
    public nonisolated static let titleTrack = "titles"
    /// A new title's length when the video allows it, and the shortest a title gets.
    public nonisolated static let titleDurationMs = 4_000
    public nonisolated static let minTitleMs = 100

    public var titles: [FlattenedTimeline.Title] { timeline.titles }
    public var selectedTitle: FlattenedTimeline.Title? { titles.first { $0.titleID == selection } }

    /// Titles on screen at `ms`.
    public func titles(at ms: Int) -> [FlattenedTimeline.Title] {
        titles.filter { ms >= $0.startMs && ms < $0.endMs }
    }

    /// A title can start at the playhead when there is video after it and no title there already.
    public var canAddTitle: Bool {
        !isEmpty && timeline.durationMs - playheadMs >= Self.minTitleMs && titles(at: playheadMs).isEmpty
    }

    /// Adds a title at the playhead in the kit's look: up to `titleDurationMs`, stopping at the end of the video or the
    /// next title. `text` maps locale → text; blank lines are left out.
    public func addTitle(_ kind: EditorTitleKind, text: [String: String], brand: TitleBrand) {
        guard !isEmpty else { return }
        let text = Self.cleaned(text)
        guard !text.isEmpty else { return fail("studio.editor.titles.error.text") }
        let start = playheadMs
        let next = titles.filter { $0.startMs > start }.map(\.startMs).min() ?? .max
        let end = min(start + Self.titleDurationMs, timeline.durationMs, next)
        guard titles(at: start).isEmpty, end - start >= Self.minTitleMs else {
            return fail("studio.editor.titles.error.room")
        }
        do {
            let (withTrack, trackID) = try Self.addingTitleTrack(to: project)
            let title = FlattenedTimeline.Title(
                titleID: "title-\(makeID())", trackID: trackID, startMs: start, durationMs: end - start, text: text,
                style: brand.style(for: kind))
            commit(try edlApply(project: withTrack, op: ["op": "addTitle", "trackId": trackID, "title": title.edlObject]))
            selection = title.titleID
        } catch {
            AUNLog.studio.info("Adding a title refused: \(error)")
            fail("studio.editor.error.refused")
        }
    }

    /// Replaces a title (same id) through `setTitle`.
    @discardableResult
    func setTitle(_ title: FlattenedTimeline.Title) -> Bool {
        apply(["op": "setTitle", "title": title.edlObject], refused: "studio.editor.error.refused")
    }

    /// Moves a title, keeping its length, within the video.
    public func moveTitle(_ id: String, toMs startMs: Int) {
        guard let title = titles.first(where: { $0.titleID == id }) else { return }
        let start = min(max(0, startMs), max(0, timeline.durationMs - title.durationMs))
        retimeTitle(id, startMs: start, endMs: start + title.durationMs)
    }

    /// New times (an edge drag, or start/end at the playhead), kept inside the video, at least `minTitleMs`, never
    /// over another title.
    public func retimeTitle(_ id: String, startMs: Int, endMs: Int) {
        guard var title = titles.first(where: { $0.titleID == id }) else { return }
        let start = max(0, startMs)
        let end = min(endMs, timeline.durationMs)
        guard end - start >= Self.minTitleMs else { return fail("studio.editor.titles.error.length") }
        guard !titles.contains(where: { $0.titleID != id && $0.trackID == title.trackID && start < $0.endMs && $0.startMs < end })
        else { return fail("studio.editor.titles.error.overlap") }
        guard start != title.startMs || end != title.endMs else { return }
        title.startMs = start
        title.durationMs = end - start
        setTitle(title)
    }

    /// Starts the title at the playhead (its end stays), or ends it there (its start stays).
    public func titleEdgeToPlayhead(_ id: String, start: Bool) {
        guard let title = titles.first(where: { $0.titleID == id }) else { return }
        if start {
            retimeTitle(id, startMs: playheadMs, endMs: title.endMs)
        } else {
            retimeTitle(id, startMs: title.startMs, endMs: playheadMs)
        }
    }

    /// New wording for the given locales; other languages the title carries stay. A title needs at least one line.
    public func setTitleText(_ id: String, text changes: [String: String]) {
        guard var title = titles.first(where: { $0.titleID == id }) else { return }
        var text = title.text
        for (locale, value) in changes { text[locale] = value }
        text = Self.cleaned(text)
        guard !text.isEmpty else { return fail("studio.editor.titles.error.text") }
        guard text != title.text else { return }
        title.text = text
        setTitle(title)
    }

    /// Makes a title a centred title or a lower third, restyled from the current kit.
    public func setTitleKind(_ id: String, _ kind: EditorTitleKind, brand: TitleBrand) {
        guard var title = titles.first(where: { $0.titleID == id }) else { return }
        let style = brand.style(for: kind)
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

    nonisolated static func cleaned(_ text: [String: String]) -> [String: String] {
        text.compactMapValues {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The project's first unlocked, unmuted title track (a project from another app may have one), adding
    /// `titleTrack` when there is none (Core has no op for tracks).
    nonisolated static func addingTitleTrack(to project: String) throws -> (project: String, trackID: String) {
        guard var object = object(project) else { throw CoreError.decoding }
        var tracks = (object["tracks"] as? [[String: Any]]) ?? []
        if let existing = tracks.first(where: {
            $0["kind"] as? String == "title" && $0["locked"] as? Bool != true && $0["muted"] as? Bool != true
        })?["id"] as? String, !existing.isEmpty {
            return (project, existing)
        }
        var trackID = titleTrack
        while tracks.contains(where: { $0["id"] as? String == trackID }) { trackID += "_" }
        tracks.append(["id": trackID, "kind": "title"])
        object["tracks"] = tracks
        return (try json(object), trackID)
    }
}

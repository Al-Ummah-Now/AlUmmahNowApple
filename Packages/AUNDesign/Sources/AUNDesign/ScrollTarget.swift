import SwiftUI

/// UI automation (`-AUNScrollTo <id>`): a screen with that section scrolls it to the top once its content is in, so
/// a screenshot of the lower part starts at a section edge instead of mid-card.
public enum ScrollTarget {
    public static var requested: String? { UserDefaults.standard.string(forKey: "AUNScrollTo") }

    /// The section to land on among `ids`, following `aliases` (a target that also opens something in that section).
    public static func target(among ids: [String], aliases: [String: String] = [:]) -> String? {
        requested.map { aliases[$0] ?? $0 }.flatMap { ids.contains($0) ? $0 : nil }
    }
}

/// Room after the last section while a target is requested, so a section near the end of a short page still scrolls
/// all the way up instead of stopping wherever the page ends; the landing edge is then the same in every language,
/// however tall each language's type is. Content, not a scroll inset: `contentMargins` threw `scrollTo` off by
/// hundreds of points on iOS. Put it last in the scroll view's content.
public struct ScrollTargetRoom: View {
    private let shows: Bool

    public init(among ids: [String], aliases: [String: String] = [:]) {
        shows = ScrollTarget.target(among: ids, aliases: aliases) != nil
    }

    public var body: some View {
        if shows { Color.clear.frame(height: 1_400).accessibilityHidden(true) }
    }
}

extension View {
    /// Marks the top edge of a section `-AUNScrollTo` can land on, with a 1-point marker one spacing step above it, so
    /// the section lands with air under the header. Never put one inside a `ViewThatFits`: it keeps every candidate
    /// layout, so the id would exist once per candidate. Mark the `ViewThatFits` itself. In a lazy stack use `.id` on
    /// the `ForEach` child instead: the stack only knows those ids before a row is built.
    public func scrollSection(_ id: String) -> some View {
        overlay(alignment: .top) {
            Color.clear.frame(height: 1)
                .alignmentGuide(.top) { $0[.top] + FanousScale.spacingMd }
                .id(id).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// Scrolls `proxy` to the requested section, if this screen has it, once `ready`. The scroll content ends with a
    /// `ScrollTargetRoom` for the same ids.
    public func scrollsToRequestedSection(
        _ proxy: ScrollViewProxy, among ids: [String], aliases: [String: String] = [:], ready: Bool
    ) -> some View {
        let target = ScrollTarget.target(among: ids, aliases: aliases)
        return task(id: ready) {
            guard ready, let target else { return }
            try? await Task.sleep(for: .milliseconds(400))
            proxy.scrollTo(target, anchor: .top)
        }
    }
}

import SwiftUI

/// UI automation (`-AUNScrollTo <id>`): a screen with that section scrolls it to the top once its content is in, so
/// a screenshot of the lower part starts at a section edge instead of mid-card.
public enum ScrollTarget {
    public static var requested: String? { UserDefaults.standard.string(forKey: "AUNScrollTo") }
}

extension View {
    /// Scrolls `proxy` to the requested section, if this screen has it, once `ready`. `aliases` name other targets that
    /// land on one of `ids` (a target that also opens something inside that section).
    ///
    /// The section always reaches the top: while a target is requested the scroll content gets a bottom margin of a
    /// screen, so a section near the end of a short page still scrolls all the way up instead of stopping wherever the
    /// page ends. The landing edge is then the same in every language, however tall each language's type is.
    public func scrollsToRequestedSection(
        _ proxy: ScrollViewProxy, among ids: [String], aliases: [String: String] = [:], ready: Bool
    ) -> some View {
        let target = ScrollTarget.requested.map { aliases[$0] ?? $0 }.flatMap { ids.contains($0) ? $0 : nil }
        return contentMargins(.bottom, target == nil ? 0 : 1_400, for: .scrollContent)
            .task(id: ready) {
                guard ready, let target else { return }
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo(target, anchor: .top)
            }
    }
}

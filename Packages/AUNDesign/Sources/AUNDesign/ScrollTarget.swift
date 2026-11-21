import SwiftUI

/// UI automation (`-AUNScrollTo <id>`): a screen with that section scrolls it to the top once its content is in, so
/// a screenshot of the lower part starts at a section edge instead of mid-card.
public enum ScrollTarget {
    public static var requested: String? { UserDefaults.standard.string(forKey: "AUNScrollTo") }
}

extension View {
    /// Scrolls `proxy` to the requested section, if this screen has it, once `ready`.
    public func scrollsToRequestedSection(_ proxy: ScrollViewProxy, among ids: [String], ready: Bool) -> some View {
        task(id: ready) {
            guard ready, let target = ScrollTarget.requested, ids.contains(target) else { return }
            try? await Task.sleep(for: .milliseconds(400))
            proxy.scrollTo(target, anchor: .top)
        }
    }
}

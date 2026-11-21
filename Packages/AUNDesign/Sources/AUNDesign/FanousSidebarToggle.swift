#if os(macOS)
    import AppKit
    import SwiftUI

    /// The Mac sidebar button in the header's own icon colour, with no glass behind it. The system button's glass
    /// follows the window, so in light mode it was a white circle on the dark header, and in a right-to-left window
    /// its glyph went white on white. It sends the same action as View > Toggle Sidebar, so the split view keeps
    /// its own column state and widths (a bound column visibility opened the sidebar below its minimum width).
    public struct FanousSidebarToggle: ToolbarContent {
        public init() {}

        public var body: some ToolbarContent {
            if #available(macOS 26, *) {
                item.sharedBackgroundVisibility(.hidden)
            } else {
                item
            }
        }

        private var item: some ToolbarContent {
            ToolbarItem(placement: .navigation) { SidebarButton() }
        }
    }

    private struct SidebarButton: View {
        @Environment(\.fanous) private var theme
        @Environment(\.l10n) private var l10n

        var body: some View {
            Button {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            } label: {
                Image(systemName: "sidebar.leading")
                    .foregroundStyle(Color(theme.parts.navIcon))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n("common.sidebar"))
            .accessibilityLabel(l10n("common.sidebar"))
            .accessibilityIdentifier("sidebar-toggle")
        }
    }
#endif

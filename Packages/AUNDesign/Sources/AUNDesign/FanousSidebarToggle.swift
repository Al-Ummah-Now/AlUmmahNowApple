#if os(macOS)
    import SwiftUI

    /// The Mac sidebar button in the header's own icon colour, with no glass behind it. The system button's glass
    /// follows the window, so in light mode it was a white circle on the dark header, and in a right-to-left window
    /// its glyph went white on white.
    public struct FanousSidebarToggle: ToolbarContent {
        @Binding private var columns: NavigationSplitViewVisibility

        public init(columns: Binding<NavigationSplitViewVisibility>) { _columns = columns }

        public var body: some ToolbarContent {
            if #available(macOS 26, *) {
                item.sharedBackgroundVisibility(.hidden)
            } else {
                item
            }
        }

        private var item: some ToolbarContent {
            ToolbarItem(placement: .navigation) { SidebarButton(columns: $columns) }
        }
    }

    private struct SidebarButton: View {
        @Environment(\.fanous) private var theme
        @Environment(\.l10n) private var l10n
        @Binding var columns: NavigationSplitViewVisibility

        var body: some View {
            Button {
                withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
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

import SwiftUI

// A sidebar row for the Mac (and iPad) sidebars; tvOS has no list row separators and no such sidebar.
#if !os(tvOS)
    /// A Mac sidebar section: the active one in the theme's gold "active" material, not the system accent. A gold accent
    /// would put white text on gold (below 4.5:1), and blue is not the brand. Studio and the Viewer share it.
    public struct FanousSidebarRow: View {
        private let title: String
        private let icon: String
        private let selected: Bool
        private let action: () -> Void

        public init(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.selected = selected
            self.action = action
        }

        public var body: some View {
            Button(action: action) {
                // Icon and title centred on each other, not a Label: a Label sets the icon on the title's baseline, which
                // sits at a different height in the Arabic line, so the rows came out a pixel taller in Arabic.
                HStack(spacing: 8) {
                    // One icon column: every glyph centred in the same width, so labels line up.
                    Image(systemName: icon)
                        .foregroundStyle(selected ? Fanous.part(\.drawerActiveText) : Fanous.part(\.drawerIcon))
                        .frame(width: 20, alignment: .center)
                        .accessibilityHidden(true)
                    Text(title)
                        .foregroundStyle(selected ? Fanous.part(\.drawerActiveText) : Fanous.part(\.drawerText))
                        .fontWeight(selected ? .semibold : .regular)
                        // A fixed line box: the taller Arabic line made each row half a point taller, so the
                        // sections and the selection sat lower and lower down the sidebar in Arabic.
                        .fanousLineBox(.caption)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if selected { FanousSurfaceKind(kind: .active, shape: .rounded(8)) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
#endif

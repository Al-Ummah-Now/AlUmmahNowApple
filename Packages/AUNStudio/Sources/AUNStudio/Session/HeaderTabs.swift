#if os(iOS)
    import AUNDesign
    import SwiftUI

    /// iPad's tabs, on the header the way the web header draws its navigation: a `navSearchBg` capsule outlined in
    /// `navSearchBorder`, each tab in `navText`, the selected one on `navActiveBg` outlined in `navIndicator`, in `navActiveText`. The header is dark
    /// in every mode, so the tabs look the same on every screen and in every theme.
    struct HeaderTabs<ID: Hashable>: View {
        struct Item: Identifiable {
            let id: ID
            let title: String
        }

        @Environment(\.fanous) private var theme
        @Environment(\.l10n) private var l10n
        let tabs: [Item]
        @Binding var selection: ID
        /// The tab that shows `badge` (Upload: the uploads in progress), when it is above zero.
        let badged: ID
        let badge: Int

        var body: some View {
            let parts = theme.parts
            HStack(spacing: FanousScale.spacingXs) {
                ForEach(tabs) { item in
                    let selected = item.id == selection
                    Button {
                        selection = item.id
                    } label: {
                        HStack(spacing: FanousScale.spacingXs) {
                            Text(item.title)
                            if item.id == badged, badge > 0 {
                                Text(DisplayFormat.number(badge, l10n.language))
                                    .font(.system(size: 12, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Fanous.onPrimary)
                                    .padding(.horizontal, 6)
                                    .frame(minWidth: 20, minHeight: 20)
                                    .background(Capsule().fill(Fanous.primary))
                            }
                        }
                        .font(.system(size: 15, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Color(selected ? parts.navActiveText : parts.navText))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background {
                            if selected {
                                // Some themes' active fill is the capsule's own colour: the indicator line marks it.
                                Capsule().fill(Color(parts.navActiveBg))
                                    .overlay(Capsule().strokeBorder(Color(parts.navIndicator), lineWidth: 1))
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityIdentifier("header-tab-\(item.id)")
                }
            }
            .padding(4)
            .background(Capsule().fill(Color(parts.navSearchBg)))
            .overlay(Capsule().strokeBorder(Color(parts.navSearchBorder), lineWidth: 1))
            .fixedSize()
        }
    }

    /// `HeaderTabs` in the middle of the navigation bar, with no glass capsule of its own on iOS 26.
    struct HeaderTabsItem<ID: Hashable>: ToolbarContent {
        let tabs: HeaderTabs<ID>

        var body: some ToolbarContent {
            if #available(iOS 26, *) {
                ToolbarItem(placement: .principal) { tabs }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { tabs }
            }
        }
    }
#endif

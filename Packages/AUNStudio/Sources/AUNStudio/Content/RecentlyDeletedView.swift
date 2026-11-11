import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Videos deleted in the last 30 days: restore them, or delete them for good now.
struct RecentlyDeletedView: View {
    @Environment(\.l10n) private var l10n
    @State private var model: DeletedModel
    @State private var confirmingPurge: [String]?

    init(services: StudioServices, channelID: String) {
        _model = State(initialValue: DeletedModel(channelID: channelID, services: services))
    }

    var body: some View {
        // One container, not a Group: a Group's modifiers attach to each branch and restart when the branch changes.
        VStack(spacing: 0) {
            if model.failed && model.items.isEmpty {
                ErrorStateView { Task { await model.load() } }
            } else if !model.loaded {
                ThemeLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                EmptyStateView(title: l10n("studio.deleted.empty"), message: l10n("studio.deleted.emptyMessage"))
            } else {
                List(selection: $model.selection) {
                    Section {
                        ForEach(model.items) { item in
                            row(item).tag(item.id).listRowBackground(Rectangle().fill(Fanous.surface))
                        }
                    } footer: {
                        Text(l10n("studio.deleted.footer"))
                    }
                }
                .scrollContentBackground(.hidden)
                #if os(iOS)
                    .environment(\.editMode, .constant(.active))
                #endif
            }
        }
        .safeAreaInset(edge: .bottom) { if !model.selection.isEmpty { actions } }
        .fanousPage()
        .navigationTitle(l10n("studio.deleted.title"))
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: Binding(get: { confirmingPurge != nil }, set: { if !$0 { confirmingPurge = nil } })) {
            let ids = confirmingPurge ?? []
            ConfirmSheet(
                title: l10n("studio.deleted.purgeTitle", ids.count.formatted(.number.locale(l10n.language.locale))),
                message: l10n("studio.deleted.purgeMessage"), actionTitle: l10n("studio.deleted.purge")
            ) {
                Task { await model.purge(ids) }
            }
        }
        .overlay(alignment: .bottom) { MessageBanner(message: $model.message) }
    }

    private func row(_ item: DeletedVideo) -> some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
            Text(item.title).fanousFont(.body).foregroundStyle(Fanous.textPrimary).lineLimit(2)
            Text(status(item)).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deleted-\(item.id)")
    }

    private func status(_ item: DeletedVideo) -> String {
        let date = item.purgeAfter.map { $0.formatted(.dateTime.day().month().year().locale(l10n.language.locale)) } ?? ""
        switch item.status {
        case .queued: return l10n("studio.deleted.queued")
        case .purging, .purged: return l10n("studio.deleted.purging")
        case .deleted: return l10n("studio.deleted.until", date)
        }
    }

    private var actions: some View {
        let ids = Array(model.selection)
        return HStack(spacing: FanousScale.spacingMd) {
            Button(l10n("studio.deleted.restore")) { Task { await model.restore(ids) } }
                .buttonStyle(FanousButtonStyle(.primary))
                .disabled(!model.items.filter { ids.contains($0.id) }.allSatisfy(\.canRestore))
                .accessibilityIdentifier("deleted-restore")
            Button(l10n("studio.deleted.purge")) { confirmingPurge = ids }
                .buttonStyle(FanousButtonStyle(.secondary))
                .accessibilityIdentifier("deleted-purge")
        }
        .padding(FanousScale.spacingMd)
        .frame(maxWidth: .infinity)
        .background(Fanous.surfaceRaised)
    }
}

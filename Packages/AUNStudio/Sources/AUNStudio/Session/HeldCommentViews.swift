import AUNCoreBridge
import AUNDesign
import SwiftUI

struct HeldCommentsSection: View {
    @Environment(\.l10n) private var l10n
    @State private var commentSheet: HeldCommentSheet?
    let model: DashboardModel

    var body: some View {
        DashboardSection(
            title: l10n("studio.home.held"), phase: model.heldPhase, empty: l10n("studio.home.heldEmpty"),
            identifier: "dashboard-held", retry: { Task { await model.loadHeld() } }
        ) {
            Text(l10n("studio.home.heldCount", DisplayFormat.count(model.held.total, l10n.language)))
                .fanousFont(.label).foregroundStyle(Fanous.accent)
            if model.isActingOnHeldComment {
                ProgressView().accessibilityLabel(l10n("common.loading"))
            }
            ForEach(model.held.items) { comment in
                HeldCommentRow(
                    comment: comment, isBusy: model.isActingOnHeldComment,
                    authorHidden: comment.authorUserID.map { model.hiddenAuthors.contains($0) } ?? false,
                    approve: { actOnComment(comment, action: .moderate(.approve)) },
                    present: { commentSheet = $0 })
            }
        }
        .sheet(item: $commentSheet) { sheet in
            HeldCommentActionSheet(sheet: sheet, act: actOnComment)
        }
    }

    private func actOnComment(_ comment: HeldComment, action: DashboardModel.CommentAction) {
        Task { await model.actOnHeldComment(comment, action: action) }
    }
}

enum HeldCommentSheet: Identifiable {
    case remove(HeldComment)
    case report(HeldComment)
    case hideAuthor(HeldComment)

    var id: String {
        switch self {
        case .remove(let comment): "remove-\(comment.id)"
        case .report(let comment): "report-\(comment.id)"
        case .hideAuthor(let comment): "hide-\(comment.id)"
        }
    }
}

struct HeldCommentRow: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let comment: HeldComment
    let isBusy: Bool
    let authorHidden: Bool
    let approve: () -> Void
    let present: (HeldCommentSheet) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: FanousScale.spacingXs) {
            VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                Text(comment.authorName).fanousFont(.label).foregroundStyle(Fanous.textPrimary)
                Text(comment.text).fanousFont(.body).foregroundStyle(Fanous.textPrimary).lineLimit(3)
                Text(comment.displayTargetTitle(l10n.language)).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                if comment.isHeldByModeration {
                    Text(l10n("studio.held.platformHold")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                }
                if authorHidden {
                    Text(l10n("studio.held.authorHidden")).fanousFont(.caption).foregroundStyle(Fanous.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Menu {
                if comment.canModerate {
                    Button(l10n("studio.held.approve"), action: approve)
                }
                Button(l10n("studio.held.report")) { present(.report(comment)) }
                if comment.canModerate {
                    Button(l10n("studio.held.remove"), role: .destructive) { present(.remove(comment)) }
                }
                if comment.authorUserID != nil && !authorHidden {
                    Button(l10n("studio.held.hideAuthor"), role: .destructive) { present(.hideAuthor(comment)) }
                }
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(isBusy)
            .accessibilityLabel(l10n("studio.held.actions"))
            .accessibilityIdentifier("held-actions-\(comment.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("held-\(comment.id)")
    }
}

struct HeldCommentActionSheet: View {
    @Environment(\.l10n) private var l10n
    let sheet: HeldCommentSheet
    let act: (HeldComment, DashboardModel.CommentAction) -> Void

    var body: some View {
        content
            #if os(macOS)
                .frame(minWidth: 480, minHeight: 360)
            #endif
    }

    @ViewBuilder private var content: some View {
        switch sheet {
        case .remove(let comment):
            ConfirmSheet(
                title: l10n("studio.held.remove"), message: l10n("studio.held.removeMessage"),
                actionTitle: l10n("studio.held.remove")
            ) { act(comment, .moderate(.remove)) }
        case .hideAuthor(let comment):
            ConfirmSheet(
                title: l10n("studio.held.hideAuthor"), message: l10n("studio.held.hideMessage"),
                actionTitle: l10n("studio.held.hideAuthor")
            ) { act(comment, .hideAuthor) }
        case .report(let comment):
            HeldCommentReportSheet { reason, description in
                act(comment, .report(reason, description: description))
            }
        }
    }
}

struct HeldCommentReportSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var reason: CommentReportReason?
    @State private var details = ""

    let submit: (CommentReportReason, String?) -> Void

    // The server validates the JavaScript string length.
    private static let detailsLimit = 5_000
    private var detailsTooLong: Bool { details.utf16.count > Self.detailsLimit }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(l10n("studio.held.reportReason"), selection: $reason) {
                        Text(l10n("studio.held.chooseReason")).tag(nil as CommentReportReason?)
                        ForEach(CommentReportReason.allCases, id: \.self) { reason in
                            Text(l10n("studio.held.reason.\(reason.rawValue)")).tag(Optional(reason))
                        }
                    }
                    TextField(l10n("studio.held.reportDetails"), text: $details, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    if detailsTooLong {
                        Text(l10n("studio.error.held.detailsLength", DisplayFormat.number(Self.detailsLimit, l10n.language)))
                            .foregroundStyle(Fanous.errorText)
                    }
                }
                .studioRows()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .fanousPage()
            .navigationTitle(l10n("studio.held.report"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n("studio.held.sendReport")) {
                        guard let reason else { return }
                        let description = details.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                        submit(reason, description.isEmpty ? nil : description)
                    }
                    .disabled(reason == nil || detailsTooLong)
                }
            }
        }
        .environment(\.layoutDirection, l10n.language.isRTL ? .rightToLeft : .leftToRight)
    }
}

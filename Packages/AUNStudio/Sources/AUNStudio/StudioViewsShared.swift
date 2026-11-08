import AUNDesign
import SwiftUI

struct StatusLabel: View {
    @Environment(\.l10n) private var l10n
    let status: QueueItemStatus

    var body: some View {
        Text(l10n(key)).font(.caption).foregroundStyle(status == .failed ? Fanous.error : Fanous.textSecondary)
    }

    private var key: String {
        switch status {
        case .waiting: "studio.status.waiting"
        case .running: "studio.status.running"
        case .done: "studio.status.done"
        case .failed: "studio.status.failed"
        }
    }
}

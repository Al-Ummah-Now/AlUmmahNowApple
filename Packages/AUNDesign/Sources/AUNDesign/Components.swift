import AUNCoreBridge
import SwiftUI

/// Remote thumbnail with a branded placeholder.
public struct ThumbnailImage: View {
    private let url: URL?

    public init(url: URL?) { self.url = url }

    public var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(Fanous.surface)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFill() }
                    }
                }
            }
            .clipped()
    }
}

/// Full-area error with a retry action.
public struct ErrorStateView: View {
    @Environment(\.l10n) private var l10n
    private let retry: () -> Void

    public init(retry: @escaping () -> Void) { self.retry = retry }

    public var body: some View {
        VStack(spacing: 16) {
            Text(l10n("common.error.load")).foregroundStyle(Fanous.textPrimary).multilineTextAlignment(.center)
            Button(l10n("common.retry"), action: retry).buttonStyle(.borderedProminent).accessibilityIdentifier("retry")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

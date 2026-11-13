import AUNCoreBridge
import AUNDesign
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// A review frame decoded in memory only: fetched through the private session, held in view state, gone when the view
/// is. Never the system async image view (it uses the shared URL cache, which writes to disk); not dragged or copied.
struct PrivateImage: View {
    @Environment(\.l10n) private var l10n
    let reviewID: String
    let key: String
    let blurred: Bool
    let service: any ReviewServicing
    @State private var image: Image?
    @State private var failed = false

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(Fanous.surfaceRaised)
            .overlay {
                if let image {
                    image.resizable().scaledToFill()
                        .blur(radius: blurred ? 28 : 0, opaque: true)
                        .accessibilityHidden(true)
                } else if failed {
                    Image(systemName: "photo").foregroundStyle(Fanous.textMuted).accessibilityHidden(true)
                } else {
                    ProgressView().accessibilityHidden(true)
                }
            }
            .overlay {
                if blurred {
                    Image(systemName: "eye.slash").font(.title3).foregroundStyle(Fanous.textPrimary)
                        .padding(FanousScale.spacingSm).background(Fanous.surface, in: Circle())
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .task(id: key) { await load() }
    }

    private func load() async {
        do {
            let data = try await service.media(reviewID, key: key)
            image = Self.decode(data)
            failed = image == nil
        } catch {
            failed = true
        }
    }

    /// Bytes to an image, in memory.
    static func decode(_ data: Data) -> Image? {
        #if canImport(UIKit)
            UIImage(data: data).map { Image(uiImage: $0) }
        #else
            NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }
}

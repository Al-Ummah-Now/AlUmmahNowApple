import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Draws the current cue above the transport controls.
public struct SubtitleOverlay: View {
    let controller: PlayerController
    var openCredit: (@MainActor (URL) -> Void)?
    var creditFrameChanged: (@MainActor (CGRect) -> Void)?
    var hostedTheme: FanousTheme?
    @Environment(\.fanous) private var theme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.openURL) private var openURL
    #if !os(tvOS)
        @ScaledMetric(relativeTo: .callout) private var creditSize = 12
    #endif

    public init(controller: PlayerController) { self.controller = controller }

    public var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let caption = controller.currentCue?.quranCaption {
                VStack(alignment: .trailing, spacing: 2) {
                    if !caption.text.isEmpty {
                        Text(caption.text)
                            .font(.callout.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background {
                                if caption.credited {
                                    cueScrim
                                } else {
                                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.7))
                                }
                            }
                            .accessibilityIdentifier("subtitle-cue")
                            .allowsHitTesting(false)
                    }
                    if let language = caption.language {
                        credit(language)
                    }
                }
                .environment(
                    \.layoutDirection, caption.language.map { $0 == .ar ? .rightToLeft : .leftToRight } ?? layoutDirection
                )
                .padding(.bottom, caption.credited ? 64 : 44)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "subtitle-overlay")
    }

    private var cueScrim: some View {
        FanousSurface(fills: (hostedTheme ?? theme).player.cue, shape: .rounded(6))
    }

    @ViewBuilder
    private func credit(_ language: QuranCaptionCredit.Language) -> some View {
        #if os(tvOS)
            let text = Text(language.label).fanousFont(.tvBody)
        #else
            let text = Text(language.label)
                .font(.system(size: creditSize, weight: .semibold))
                .underline()
        #endif
        let label =
            text
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background { cueScrim }

        #if os(tvOS)
            label.allowsHitTesting(false)
        #else
            let accessibleLabel = L10n(language == .ar ? .ar : .en)("player.quranCredit.accessibility")
            Button {
                if let openCredit {
                    openCredit(QuranCaptionCredit.url)
                } else {
                    openURL(QuranCaptionCredit.url)
                }
            } label: {
                #if os(iOS)
                    label
                        .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                        .contentShape(Rectangle())
                #else
                    label
                #endif
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibleLabel)
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier("quran-caption-credit")
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("subtitle-overlay"))
            } action: { frame in
                creditFrameChanged?(frame)
            }
            .onDisappear { creditFrameChanged?(.null) }
        #endif
    }
}

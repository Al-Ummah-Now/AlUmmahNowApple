import AUNCoreBridge
import AUNDesign
import SwiftUI

/// Terms of Service and Community Guidelines agreement shown once per account before the first upload
/// (Play UGC / App Store 1.2, AlUmmahNowApple#93, AlUmmahNowAndroid#65).
struct CreatorTermsGateView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let session: StudioSession
    @State private var agreed: Bool
    /// The Terms version shown to the creator when the gate opened (pinned until bumped on 409 / refresh).
    @State private var shownVersion: String?
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var linkIconWidth: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var checkboxSize: CGFloat = 22

    init(session: StudioSession, initialAgreed: Bool = false) {
        self.session = session
        _agreed = State(initialValue: initialAgreed)
        _shownVersion = State(initialValue: session.termsVersion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FanousScale.spacingLg) {
            HStack(alignment: .top, spacing: FanousScale.spacingMd) {
                Image(systemName: "checkmark.shield")
                    .font(.title2)
                    .foregroundStyle(Fanous.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                    Text(l10n("studio.terms.title"))
                        .font(.system(size: titleSize, weight: .bold))
                        .foregroundStyle(Fanous.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(l10n(session.termsUpdatedWhileOpen ? "studio.terms.updatedBody" : "studio.terms.body"))
                        .font(.system(size: bodySize))
                        .foregroundStyle(Fanous.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                Link(destination: AUNSupportLinks.terms(language: l10n.language.rawValue, environment: session.environment)) {
                    HStack(alignment: .firstTextBaseline, spacing: FanousScale.spacingSm) {
                        Image(systemName: "doc.text")
                            .frame(width: linkIconWidth, alignment: .center)
                            .accessibilityHidden(true)
                        Text(l10n("common.termsOfService"))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("creator-terms-link")
                Link(
                    destination: AUNSupportLinks.communityGuidelines(
                        language: l10n.language.rawValue, environment: session.environment)
                ) {
                    HStack(alignment: .firstTextBaseline, spacing: FanousScale.spacingSm) {
                        Image(systemName: "book")
                            .frame(width: linkIconWidth, alignment: .center)
                            .accessibilityHidden(true)
                        Text(l10n("common.communityGuidelines"))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("creator-guidelines-link")
            }
            .font(.system(size: labelSize, weight: .semibold))
            .foregroundStyle(Fanous.accent)

            Button {
                guard !session.isAcceptingTerms else { return }
                agreed.toggle()
            } label: {
                HStack(alignment: .top, spacing: FanousScale.spacingSm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(agreed ? Fanous.primary : Fanous.surfaceRaised)
                            .frame(width: checkboxSize, height: checkboxSize)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(agreed ? Fanous.primary : Fanous.textPrimary, lineWidth: 2)
                            .frame(width: checkboxSize, height: checkboxSize)
                        if agreed {
                            Image(systemName: "checkmark")
                                .font(.system(size: max(12, checkboxSize * 0.55), weight: .bold))
                                .foregroundStyle(Fanous.onPrimary)
                        }
                    }
                    .padding(.top, 1)
                    Text(l10n("studio.terms.checkbox"))
                        .font(.system(size: bodySize))
                        .foregroundStyle(Fanous.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(NonDimmingPlainButtonStyle())
            .disabled(session.isAcceptingTerms)
            .accessibilityAddTraits(agreed ? .isSelected : [])
            .accessibilityIdentifier("creator-terms-toggle")

            if let notice = session.termsNotice {
                noticeBanner(notice)
            }

            let canAgree = agreed && !session.isAcceptingTerms
            Button {
                let versionAtTap = shownVersion
                Task { await session.acceptCreatorTerms(shownVersion: versionAtTap) }
            } label: {
                if session.isAcceptingTerms {
                    HStack(spacing: FanousScale.spacingSm) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Fanous.textPrimary)
                        Text(l10n("studio.terms.saving"))
                            .font(.system(size: labelSize, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(l10n("studio.terms.agree"))
                        .font(.system(size: labelSize, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(TermsAgreeButtonStyle(isActive: canAgree))
            .disabled(!canAgree)
            .accessibilityLabel(l10n(session.isAcceptingTerms ? "studio.terms.saving" : "studio.terms.agree"))
            .accessibilityIdentifier("creator-terms-agree")
        }
        .padding(FanousScale.spacingXl)
        .frame(maxWidth: 520, alignment: .leading)
        .fanousMaterial(.card) { .rounded($0.xl) }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("creator-terms-gate")
        .onChange(of: session.termsVersion) { old, next in
            guard let next, !next.isEmpty else { return }
            if shownVersion == nil || next != old {
                shownVersion = next
                agreed = false
            }
        }
        .onChange(of: session.termsVersionBumpSerial) { _, _ in
            agreed = false
            shownVersion = session.termsVersion
        }
    }

    @ViewBuilder private func noticeBanner(_ notice: StudioNotice) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: FanousScale.spacingSm) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: min(labelSize, 28)))
                        .accessibilityHidden(true)
                    Text(l10n(notice.key))
                        .font(.system(size: labelSize, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(l10n("common.dismiss")) { session.termsNotice = nil }
                        .buttonStyle(.borderless)
                        .font(.system(size: labelSize, weight: .semibold))
                        .frame(minHeight: 44, alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: FanousScale.spacingSm) {
                    Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                    Text(l10n(notice.key))
                        .font(.system(size: labelSize, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(l10n("common.dismiss")) { session.termsNotice = nil }
                        .buttonStyle(.borderless)
                        .font(.system(size: labelSize, weight: .semibold))
                }
            }
        }
        .foregroundStyle(Fanous.errorText)
        .padding(FanousScale.spacingMd)
        .fanousMaterial(.raised) { .rounded($0.md) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notice")
        .onAppear { AccessibilityNotification.Announcement(l10n(notice.key)).post() }
        .onChange(of: notice.id) { _, _ in AccessibilityNotification.Announcement(l10n(notice.key)).post() }
    }
}

/// Keeps native `.disabled(true)` accessibility/hit-testing state while avoiding system 0.40 opacity dimming.
private struct NonDimmingPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Uses the theme's primary surface (`FanousSurfaceKind(.primary/.primaryPress)`) when active, and a high-contrast
/// raised capsule when disabled/saving (keeping native `.disabled(true)` without 0.40 dimming).
private struct TermsAgreeButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        TermsAgreeButtonBody(isActive: isActive, configuration: configuration)
    }
}

private struct TermsAgreeButtonBody: View {
    @Environment(\.fanous) private var theme
    let isActive: Bool
    let configuration: ButtonStyleConfiguration

    var body: some View {
        let pressed = isActive && configuration.isPressed
        let shape = FanousShape.rounded(theme.radius.pill)
        configuration.label
            .foregroundStyle(isActive ? Color(theme.parts.buttonPrimaryText) : Color(theme.colors.textPrimary))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                if isActive {
                    FanousSurfaceKind(kind: pressed ? .primaryPress : .primary, shape: shape)
                } else {
                    shape.fill(Fanous.surfaceRaised)
                }
            }
            .overlay {
                if isActive {
                    shape.strokeBorder(Color(theme.parts.buttonPrimaryBorder), lineWidth: 1)
                } else {
                    shape.strokeBorder(Fanous.textSecondary, lineWidth: 1)
                }
            }
            .contentShape(shape)
            .offset(y: pressed ? 1 : 0)
            .animation(.easeOut(duration: FanousScale.durationFast), value: pressed)
    }
}

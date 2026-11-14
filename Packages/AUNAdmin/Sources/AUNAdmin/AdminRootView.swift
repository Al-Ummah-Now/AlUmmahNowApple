import AUNCoreBridge
import AUNDesign
import AUNStudio
import SwiftUI

/// The Admin app's window on iPhone, iPad and Mac: sign-in, device unlock, the staff check, then the queue.
public struct AdminRootView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings
    @State private var session: AdminSession
    let capture: CaptureMonitor
    let push: AdminPush

    public init(session: AdminSession, capture: CaptureMonitor, push: AdminPush) {
        _session = State(initialValue: session)
        self.capture = capture
        self.push = push
    }

    public var body: some View {
        Group {
            switch session.phase {
            case .loading, .checking:
                ThemeLoader().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("loading")
            case .signedOut: AdminSignInView(session: session)
            case .locked: LockView(session: session)
            case .notStaff:
                GateView(
                    session: session, title: "admin.notStaff.title", message: "admin.notStaff.message",
                    identifier: "not-staff", retry: false)
            case .unverified:
                GateView(
                    session: session, title: "admin.unverified.title", message: "admin.unverified.message",
                    identifier: "unverified", retry: true)
            case .ready: AdminShell(session: session, capture: capture, push: push)
            }
        }
        .fanousPage()
        .adminPrivacy(capture)
        .task { await session.start() }
        .onAppear {
            LaunchClock.mark("root appeared")
            // Light and Dark only: the first launch follows the device, then the last explicit choice.
            if settings.theme == .system { settings.theme = colorScheme == .dark ? .dark : .light }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: session.enteredBackground()
            case .active: session.becameActive()
            default: break
            }
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .ready { push.attach(session) }
            if phase == .signedOut { push.clearAll() }
        }
    }
}

/// The first screen without an account.
struct AdminSignInView: View {
    @Environment(\.l10n) private var l10n
    let session: AdminSession

    var body: some View {
        CardPage {
            Text(l10n("admin.name")).fanousFont(.label).foregroundStyle(Fanous.accent)
            Text(l10n("admin.signIn.title")).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(l10n("admin.signIn.message")).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
            if session.isSigningIn {
                ProgressView(l10n("admin.signIn.progress")).accessibilityIdentifier("sign-in-progress")
            } else {
                Button {
                    Task { await session.signIn() }
                } label: {
                    Label(l10n("admin.signIn.button"), systemImage: "person.badge.key").frame(maxWidth: 280)
                }
                .buttonStyle(FanousButtonStyle(.primary))
                .accessibilityIdentifier("sign-in")
            }
            NoticeLine(key: session.notice)
        }
    }
}

/// Face ID, Touch ID or the passcode before anything shows. Asks at once; the button asks again.
struct LockView: View {
    @Environment(\.l10n) private var l10n
    let session: AdminSession

    var body: some View {
        CardPage {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(Fanous.accent).accessibilityHidden(true)
            Text(l10n("admin.lock.title")).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Button {
                Task { await session.unlock(reason: l10n("admin.lock.reason")) }
            } label: {
                Label(l10n("admin.lock.button"), systemImage: "faceid").frame(maxWidth: 280)
            }
            .buttonStyle(FanousButtonStyle(.primary))
            .accessibilityIdentifier("unlock")
            NoticeLine(key: session.notice)
        }
        .task { await session.unlock(reason: l10n("admin.lock.reason")) }
    }
}

/// Not staff, or the staff check could not run: say so and offer sign-out (and a retry).
struct GateView: View {
    @Environment(\.l10n) private var l10n
    let session: AdminSession
    let title: String
    let message: String
    let identifier: String
    let retry: Bool

    var body: some View {
        CardPage {
            Text(l10n(title)).fanousFont(.headline).foregroundStyle(Fanous.textPrimary)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier(identifier)
            Text(l10n(message)).fanousFont(.body).foregroundStyle(Fanous.textSecondary)
            if retry {
                Button(l10n("common.retry")) { Task { await session.checkStaff() } }
                    .buttonStyle(FanousButtonStyle(.primary))
                    .accessibilityIdentifier("retry")
            }
            Button(l10n("admin.signOut")) { Task { await session.signOut() } }
                .buttonStyle(FanousButtonStyle(.secondary))
                .accessibilityIdentifier("sign-out")
        }
    }
}

struct CardPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: FanousScale.spacingLg) {
                FanousMotif(.loader).frame(width: 64, height: 64).accessibilityHidden(true)
                content
            }
            .multilineTextAlignment(.center)
            .padding(FanousScale.spacingXl)
            .frame(maxWidth: 460)
            .fanousMaterial(.raised) { .rounded($0.xl) }
            .padding(FanousScale.spacingLg)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
    }
}

struct NoticeLine: View {
    @Environment(\.l10n) private var l10n
    let key: String?

    var body: some View {
        if let key {
            Text(l10n(key)).fanousFont(.label).foregroundStyle(Fanous.errorText).accessibilityIdentifier("notice")
        }
    }
}

/// The queue beside the open item (split view on iPad and Mac, a stack on iPhone).
struct AdminShell: View {
    @Environment(\.l10n) private var l10n
    let session: AdminSession
    let capture: CaptureMonitor
    let push: AdminPush
    @State private var queue: QueueModel
    @State private var toasts = ToastCenter()
    @State private var selection: String?
    @State private var confirmSignOut = false

    init(session: AdminSession, capture: CaptureMonitor, push: AdminPush) {
        self.session = session
        self.capture = capture
        self.push = push
        _queue = State(initialValue: session.queue ?? QueueModel(service: session.services.review, senior: session.isSenior))
    }

    var body: some View {
        NavigationSplitView {
            QueueColumn(model: queue, selection: $selection, session: session)
                .toolbar { toolbar }
                .onAppear { LaunchClock.mark("queue column appeared") }
        } detail: {
            if let selection {
                ReviewScreen(model: reviewModel(selection), capture: capture, isOffline: session.isOffline)
                    .id(selection)
            } else {
                EmptyStateView(title: l10n("admin.review.pick"), message: l10n("admin.review.pickMessage"))
            }
        }
        .overlay(alignment: .bottom) { ToastView(center: toasts) }
        .onAppear { LaunchClock.mark("shell appeared") }
        .sheet(isPresented: $confirmSignOut) {
            ConfirmSheet(
                title: l10n("admin.signOut.title"), message: l10n("admin.signOut.message"),
                actionTitle: l10n("admin.signOut")
            ) { Task { await session.signOut() } }
            .adminPrivacy(capture)
        }
        .onAppear {
            let review = session.services.review
            let install = session.installID
            capture.onEvent = { event in
                let id = selection
                Task { try? await review.recordCapture(event, reviewID: id, installID: install) }
            }
        }
        .onChange(of: push.pendingReviewID) { _, id in
            if let id {
                selection = id
                push.pendingReviewID = nil
            }
        }
        .onOpenURL { url in open(url) }
    }

    private func reviewModel(_ id: String) -> ReviewModel {
        ReviewModel(id: id, service: session.services.review, session: session, toasts: toasts, l10n: l10n) {
            [queue] item in queue.apply(item)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                selection = queue.item(after: selection, step: -1)?.id ?? selection
            } label: {
                Label(l10n("admin.queue.previous"), systemImage: "chevron.up")
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button {
                selection = queue.item(after: selection, step: 1)?.id ?? selection
            } label: {
                Label(l10n("admin.queue.next"), systemImage: "chevron.down")
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button {
                Task { await queue.load() }
            } label: {
                Label(l10n("admin.queue.refresh"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            AccountMenu(session: session, confirmSignOut: $confirmSignOut)
        }
    }

    /// `alummahnow-admin://review/<id>` opens an item; `alummahnow-admin://queue?tab=history&q=…` sets the filters.
    private func open(_ url: URL) {
        guard url.scheme == "alummahnow-admin", url.host != "auth" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host == "review", let id = parts.first, ReviewID.isValid(id) {
            selection = id
        } else if url.host == "queue" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let tab = items.first(where: { $0.name == "tab" })?.value.flatMap(ReviewTab.init(rawValue:)) { queue.tab = tab }
            if let q = items.first(where: { $0.name == "q" })?.value { queue.search(q) }
        }
    }
}

/// The signed-in reviewer, language, Light or Dark (no System option), and sign-out.
struct AccountMenu: View {
    @Environment(\.l10n) private var l10n
    @Environment(AppSettings.self) private var settings
    let session: AdminSession
    @Binding var confirmSignOut: Bool

    var body: some View {
        @Bindable var settings = settings
        Menu {
            if let name = session.profile?.displayName ?? session.account?.label { Text(name) }
            Picker(l10n("common.language"), selection: $settings.language) {
                Text(l10n("language.en")).tag(AppLanguage.en)
                Text(l10n("language.ar")).tag(AppLanguage.ar)
            }
            Picker(l10n("common.theme"), selection: $settings.theme) {
                Text(l10n("theme.light")).tag(AppTheme.light)
                Text(l10n("theme.dark")).tag(AppTheme.dark)
            }
            Divider()
            Button(l10n("admin.signOut"), role: .destructive) { confirmSignOut = true }
                .accessibilityIdentifier("sign-out")
        } label: {
            Label(l10n("admin.account"), systemImage: "person.crop.circle")
        }
        .accessibilityIdentifier("account-menu")
    }
}

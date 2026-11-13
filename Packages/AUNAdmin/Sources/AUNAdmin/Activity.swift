import AUNCoreBridge
import Foundation
import Network
import Observation

/// Whether the device is online. No decision is ever queued for later (AD8): offline, the buttons say so.
@MainActor @Observable
public final class NetworkMonitor {
    public private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    public init(forcedOffline: Bool = false) {
        guard !forcedOffline else {
            isOnline = false
            return
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "net.alummahnow.admin.network"))
    }

    deinit { monitor.cancel() }
}

/// A message at the bottom of the window, with an optional action (Undo). Reversible actions show one for 10 s.
public struct Toast: Identifiable, Equatable {
    public let id = UUID()
    public var text: String
    public var actionTitle: String?
    public var isError: Bool

    public static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// The one toast on screen, and its action.
@MainActor @Observable
public final class ToastCenter {
    public private(set) var toast: Toast?
    @ObservationIgnored private var action: (() async -> Void)?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// Undo lasts 10 seconds (AD8); after that, History has "Reverse decision" on the server's own window.
    public static let undoSeconds: Double = 10

    public init() {}

    public func show(_ text: String, actionTitle: String? = nil, isError: Bool = false, action: (() async -> Void)? = nil) {
        timer?.cancel()
        let toast = Toast(text: text, actionTitle: actionTitle, isError: isError)
        self.toast = toast
        self.action = action
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled, self?.toast?.id == toast.id else { return }
            self?.dismiss()
        }
    }

    public func perform() async {
        let action = action
        dismiss()
        await action?()
    }

    public func dismiss() {
        timer?.cancel()
        toast = nil
        action = nil
    }
}

import Foundation

/// How much diagnostic telemetry the person has opted into. Defaults to ``off``.
public enum TelemetryConsent: String, Sendable, Equatable {
    case off
    case crashOnly
    case full
}

/// Opt-in diagnostics and crash reports, shared by the Apple apps. Off until the person turns it on.
/// aun-core's telemetry does the scrubbing, the on-disk buffer, the purge on opt-out and the delivery;
/// the apps only pass consent and crashes and ask for a flush. Never throws.
public protocol TelemetryServicing: Sendable {
    var consent: TelemetryConsent { get }

    /// Applies `consent`; turning it off deletes what was kept. Returns `false` when the core refused.
    @discardableResult
    func setConsent(_ consent: TelemetryConsent) -> Bool

    /// Records a crash and writes it to disk at once, so it survives the process ending.
    func reportCrash(kind: String, message: String, stack: String?)

    /// Writes the buffer to disk (call when the app goes to the background).
    func persist()

    /// Sends what is buffered; does nothing while off or offline.
    func flush() async
}

/// Used in fixtures, previews and builds without `AUNCoreKit`.
public final class NullTelemetryService: TelemetryServicing {
    public static let shared = NullTelemetryService()

    public init() {}

    public var consent: TelemetryConsent { .off }

    @discardableResult
    public func setConsent(_ consent: TelemetryConsent) -> Bool {
        consent == .off
    }

    public func reportCrash(kind: String, message: String, stack: String?) {}
    public func persist() {}
    public func flush() async {}
}

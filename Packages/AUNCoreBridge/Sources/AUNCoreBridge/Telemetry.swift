import Foundation

/// How much diagnostic telemetry the person has opted into. Defaults to ``off`` (silent, zero disk writes, zero network).
public enum TelemetryConsent: String, Sendable, Equatable {
    case off
    case crashOnly
    case full
}

/// Severity level for diagnostic breadcrumbs attached to crash reports.
public enum TelemetryBreadcrumbSeverity: String, Sendable, Equatable {
    case debug
    case info
    case warning
    case error
}

/// Privacy-first opt-in telemetry & crash reporting contract shared across Apple apps.
/// Features and shells only see this protocol; `AUNCoreKit` provides the `aun-core` implementation.
public protocol TelemetryServicing: Sendable {
    var consent: TelemetryConsent { get }
    var pendingCount: Int { get }
    var lastPurgeFailed: Bool { get }

    /// Applies the requested consent level. Opting out immediately denies collection in the wrapper
    /// and attempts to purge any buffered data from memory and disk. Returns `true` when the transition
    /// (and purge, when opting out) succeeded, or `false` when it failed (see ``lastPurgeFailed``).
    @discardableResult
    func setConsent(_ consent: TelemetryConsent) -> Bool

    func track(_ name: String, properties: [String: String])
    func trackError(_ code: String, properties: [String: String])
    func addBreadcrumb(category: String, message: String, level: TelemetryBreadcrumbSeverity)
    func reportCrash(kind: String, message: String, stack: String?, fromPreviousSession: Bool)
    func persist()
    func flush() async
}

extension TelemetryServicing {
    public func track(_ name: String) {
        track(name, properties: [:])
    }

    public func trackError(_ code: String) {
        trackError(code, properties: [:])
    }

    public func addBreadcrumb(category: String, message: String) {
        addBreadcrumb(category: category, message: message, level: .info)
    }

    public func reportCrash(kind: String, message: String, stack: String? = nil) {
        reportCrash(kind: kind, message: message, stack: stack, fromPreviousSession: false)
    }
}

/// Silent no-op telemetry implementation used in fixtures, previews, and builds without `AUNCoreKit`.
public final class NullTelemetryService: TelemetryServicing {
    public static let shared = NullTelemetryService()

    public init() {}

    public var consent: TelemetryConsent { .off }
    public var pendingCount: Int { 0 }
    public var lastPurgeFailed: Bool { false }

    @discardableResult
    public func setConsent(_ consent: TelemetryConsent) -> Bool {
        consent == .off
    }

    public func track(_ name: String, properties: [String: String]) {}
    public func trackError(_ code: String, properties: [String: String]) {}
    public func addBreadcrumb(category: String, message: String, level: TelemetryBreadcrumbSeverity) {}
    public func reportCrash(kind: String, message: String, stack: String?, fromPreviousSession: Bool) {}
    public func persist() {}
    public func flush() async {}
}

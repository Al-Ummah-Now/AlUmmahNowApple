import AUNCoreBridge
import Foundation
import LocalAuthentication

/// Face ID, Touch ID or the device passcode (AD5): to open the app and after 5 minutes in the background.
public protocol DeviceUnlocking: Sendable {
    /// False when the device has no passcode: the Admin app then refuses to sign in.
    func hasPasscode() -> Bool
    /// Asks the person to unlock; true when they did.
    func unlock(reason: String) async -> Bool
}

/// LocalAuthentication with the device-owner policy (biometrics, falling back to the passcode).
public struct SystemDeviceUnlock: DeviceUnlocking {
    public init() {}

    public func hasPasscode() -> Bool {
        var error: NSError?
        let ok = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        if !ok, let error { AUNLog.admin.info("Device unlock unavailable: \(error.code)") }
        return ok
    }

    public func unlock(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = nil
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// UI tests and previews: `passcode` says whether the device has one, unlock always succeeds.
public struct FixtureDeviceUnlock: DeviceUnlocking {
    let passcode: Bool

    public init(passcode: Bool = true) { self.passcode = passcode }
    public func hasPasscode() -> Bool { passcode }
    public func unlock(reason: String) async -> Bool { true }
}

/// When the app must ask for the device unlock again.
public struct LockPolicy: Sendable {
    /// 5 minutes in the background (AD5).
    public var backgroundGrace: TimeInterval = 5 * 60
    /// A step-up sign-in counts for 15 minutes (`max_age=900`).
    public var stepUpWindow: TimeInterval = 15 * 60

    public init() {}

    /// Locked again when the app comes back after more than the grace period in the background.
    public func needsUnlock(backgroundedAt: Date?, now: Date) -> Bool {
        guard let backgroundedAt else { return false }
        return now.timeIntervalSince(backgroundedAt) > backgroundGrace
    }

    public func stepUpIsFresh(_ at: Date?, now: Date) -> Bool {
        guard let at else { return false }
        return now.timeIntervalSince(at) < stepUpWindow
    }
}

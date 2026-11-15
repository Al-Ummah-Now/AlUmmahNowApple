import AUNCoreBridge
import Darwin
import Foundation

/// Launch timing for the log and for the UI test that keeps the queue quick to show. The log counts from the moment
/// the kernel started the process. The UI test's number counts from the root view's first appearance to the first
/// queue row: the app's own work (session, account, queue load, layout of every row). Before it come process spawn,
/// dyld and runtime set-up (2.8-5.6 s on a 3-vCPU CI runner), then UIKit's scene connection and XCUITest's in-app
/// handshake between `App.init` and the first frame. That last part took 0.7-0.9 s on a quiet runner and 3.2 s on a
/// busy one with the app doing nothing of its own (Apple #44, 2026-11-15); it is reported separately for the log.
@MainActor
public enum LaunchClock {
    /// `-AUNReportLaunchTime YES` (UI tests) shows the first queue time as an accessibility element.
    static let reports = UserDefaults.standard.bool(forKey: "AUNReportLaunchTime")

    /// When the app's own code first ran, in seconds since the process started.
    private(set) static var codeStartedAt: Double?

    /// When the root view first appeared, in seconds since the process started.
    private(set) static var rootAppearedAt: Double?

    /// From the app's first line to the root view's first appearance, in seconds: system and test-harness work.
    static var firstFrameAfter: Double? {
        guard let codeStartedAt, let rootAppearedAt else { return nil }
        return rootAppearedAt - codeStartedAt
    }

    /// From the root view's first appearance to the first queue row, in seconds.
    private(set) static var queueShownAfter: Double?

    /// Call first thing in `App.init`.
    public static func appStarted() {
        guard codeStartedAt == nil else { return }
        let value = seconds()
        codeStartedAt = value
        AUNLog.admin.notice("Launch: app code started at \(value, format: .fixed(precision: 2)) s")
    }

    static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    static func seconds() -> Double { processStart.map { Date().timeIntervalSince($0) } ?? -1 }

    static func phase(_ phase: AdminSession.Phase) {
        let name = String(describing: phase)
        AUNLog.admin.notice("Launch: \(name, privacy: .public) at \(seconds(), format: .fixed(precision: 2)) s")
    }

    /// Call from the root view's `onAppear`; later calls keep the first time.
    static func rootAppeared() {
        guard rootAppearedAt == nil else { return }
        rootAppearedAt = seconds()
        mark("root appeared")
    }

    static func mark(_ event: String) {
        AUNLog.admin.notice("Launch: \(event, privacy: .public) at \(seconds(), format: .fixed(precision: 2)) s")
    }

    /// Records the first time a queue row appears, as seconds after the root view first appeared (after the app's code
    /// started when it has not); later calls keep the first value.
    @discardableResult static func queueShown() -> Double {
        if let queueShownAfter { return queueShownAfter }
        let now = seconds()
        let value = now - (rootAppearedAt ?? codeStartedAt ?? 0)
        queueShownAfter = value
        AUNLog.admin.notice(
            "Launch: queue shown at \(now, format: .fixed(precision: 2)) s, \(value, format: .fixed(precision: 2)) s after the root view appeared"
        )
        return value
    }
}

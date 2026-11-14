import AUNCoreBridge
import Darwin
import Foundation

/// Launch timing for the log and for the UI test that keeps the queue quick to show. The log counts from the moment
/// the kernel started the process; the UI test's number counts from the app's own first line (`App.init`), because
/// process spawn, dyld and runtime set-up before it took 2.8-5.6 s on a 3-vCPU CI runner and are not the app's code.
@MainActor
public enum LaunchClock {
    /// `-AUNReportLaunchTime YES` (UI tests) shows the first queue time as an accessibility element.
    static let reports = UserDefaults.standard.bool(forKey: "AUNReportLaunchTime")

    /// When the app's own code first ran, in seconds since the process started.
    private(set) static var codeStartedAt: Double?

    /// From the app's first line to the first queue row, in seconds.
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

    static func mark(_ event: String) {
        AUNLog.admin.notice("Launch: \(event, privacy: .public) at \(seconds(), format: .fixed(precision: 2)) s")
    }

    /// Records the first time a queue row appears, as seconds after the app's code started; later calls keep the
    /// first value.
    @discardableResult static func queueShown() -> Double {
        if let queueShownAfter { return queueShownAfter }
        let now = seconds()
        let value = now - (codeStartedAt ?? 0)
        queueShownAfter = value
        AUNLog.admin.notice(
            "Launch: queue shown at \(now, format: .fixed(precision: 2)) s, \(value, format: .fixed(precision: 2)) s after the app code started"
        )
        return value
    }
}

import AUNCoreBridge
import Darwin
import Foundation

/// Seconds since the kernel started this process (before dyld), for the launch log and for the UI test that keeps
/// the queue quick to show. Measured in the app, so simulator spawn and XCUITest session setup are not counted.
@MainActor
enum LaunchClock {
    /// `-AUNReportLaunchTime YES` (UI tests) shows the first queue time as an accessibility element.
    static let reports = UserDefaults.standard.bool(forKey: "AUNReportLaunchTime")

    /// When the first queue row appeared in this process, in seconds since the process started.
    private(set) static var queueShownAfter: Double?

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

    /// Records the first time a queue row appears; later calls keep the first value.
    @discardableResult static func queueShown() -> Double {
        if let queueShownAfter { return queueShownAfter }
        let value = seconds()
        queueShownAfter = value
        AUNLog.admin.notice("Launch: queue shown at \(value, format: .fixed(precision: 2)) s")
        return value
    }
}

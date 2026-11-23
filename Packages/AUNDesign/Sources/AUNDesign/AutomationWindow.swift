import CoreGraphics
import Foundation

/// UI automation (`-AUNWindowHeight <points>`, `-AUNWatchWindowHeight <points>`): a Mac window opens at that height
/// instead of its default, so a review frame of the window ends below whole content rather than through a card. The
/// width never changes, so the layout above the bottom edge is the same at every height.
public enum AutomationWindow {
    /// The main window's height: the automation value when there is one, else `standard`.
    public static func height(_ standard: CGFloat) -> CGFloat { value("AUNWindowHeight") ?? standard }

    /// The watch window's height (the Viewer opens each video in its own window).
    public static func watchHeight(_ standard: CGFloat) -> CGFloat { value("AUNWatchWindowHeight") ?? standard }

    /// Under an automation height, forgets the window frames AppKit saved on earlier launches: a saved frame wins over
    /// the default size, so a launch reopened at the previous launch's height. Call before any window opens.
    public static func forgetSavedFrames() {
        guard value("AUNWindowHeight") != nil || value("AUNWatchWindowHeight") != nil else { return }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame") {
            defaults.removeObject(forKey: key)
        }
    }

    private static func value(_ key: String) -> CGFloat? {
        let points = UserDefaults.standard.double(forKey: key)
        return points > 0 ? CGFloat(points) : nil
    }
}

/// UI automation (`-AUNHideScrollIndicators YES`, set by every screenshot run): scroll views draw no indicators. A
/// landing scroll (`-AUNScrollTo`) shows the overlay scroller, and a frame could catch it mid-fade.
public enum AutomationScrollIndicators {
    public static var hidden: Bool { UserDefaults.standard.bool(forKey: "AUNHideScrollIndicators") }
}

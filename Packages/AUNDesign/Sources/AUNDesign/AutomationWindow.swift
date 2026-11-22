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

    private static func value(_ key: String) -> CGFloat? {
        let points = UserDefaults.standard.double(forKey: key)
        return points > 0 ? CGFloat(points) : nil
    }
}

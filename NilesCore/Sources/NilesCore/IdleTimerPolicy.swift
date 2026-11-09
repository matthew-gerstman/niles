/// The keep-awake decision for the screen's idle timer.
///
/// Serving keeps the display awake so iOS does not suspend the LAN server
/// behind a locked screen; any other state restores the user's normal
/// auto-lock. Pure so the binding is testable without UIKit.
public enum IdleTimerPolicy {
    public static func shouldKeepScreenAwake(isServing: Bool, isAppActive: Bool) -> Bool {
        isServing && isAppActive
    }
}

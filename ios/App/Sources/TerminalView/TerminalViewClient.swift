import Foundation
import CoreGraphics
import TermuxTerminal

/// The interface for communication between `TerminalView` and its client. Port of
/// `com.termux.view.TerminalViewClient`.
///
/// Points are in the terminal content coordinate space (relative to the top left of the first
/// visible terminal line, i.e. without the terminal margins).
protocol TerminalViewClient: AnyObject {

    /// Callback function on scale events according to `UIPinchGestureRecognizer.scale`.
    /// Returns the new scale factor to continue the gesture with.
    func onScale(_ scale: CGFloat) -> CGFloat

    /// On a single tap on the terminal if terminal mouse reporting not enabled.
    func onSingleTapUp(_ terminalView: TerminalView, at point: CGPoint)

    func copyModeChanged(_ copyMode: Bool)

    /// A key with an Android key code was pressed (hardware keyboard or extra keys).
    /// `keyMod` holds the `KeyHandler.KEYMOD_*` modifiers of the event itself (not the extra keys
    /// toggles). Return `true` if the key was consumed.
    func onKeyDown(_ keyCode: Int, keyMod: Int, session: TerminalSession) -> Bool

    /// Return `true` to consume a long press (which otherwise starts text selection).
    func onLongPress(at point: CGPoint) -> Bool

    func readControlKey() -> Bool
    func readAltKey() -> Bool
    func readShiftKey() -> Bool
    func readFnKey() -> Bool

    /// Return `true` to consume a code point before it is sent to the terminal.
    func onCodePoint(_ codePoint: Int, ctrlDown: Bool, session: TerminalSession) -> Bool

    func onEmulatorSet()

    func log(_ level: LogLevel, tag: String, _ message: String)
}

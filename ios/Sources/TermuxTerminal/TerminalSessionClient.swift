import Foundation

/// Log levels used by `TerminalSessionClient.log(_:tag:_:)`.
public enum LogLevel: Int {
    case error, warn, info, debug, verbose
}

/// The interface for communication between `TerminalSession` and its client. It is used to
/// send callbacks to the client when `TerminalSession` changes or for sending other
/// back data to the client like logs.
public protocol TerminalSessionClient: AnyObject {

    func onTextChanged(_ session: TerminalSession)

    func onTitleChanged(_ session: TerminalSession)

    func onSessionFinished(_ session: TerminalSession)

    func onCopyTextToClipboard(_ session: TerminalSession, text: String)

    func onPasteTextFromClipboard(_ session: TerminalSession?)

    func onBell(_ session: TerminalSession)

    func onColorsChanged(_ session: TerminalSession)

    func onTerminalCursorStateChange(_ state: Bool)

    /// One of the `TerminalEmulator.TERMINAL_CURSOR_STYLE_*` values, or nil for the default.
    var terminalCursorStyle: Int? { get }

    func log(_ level: LogLevel, tag: String, _ message: String)
}

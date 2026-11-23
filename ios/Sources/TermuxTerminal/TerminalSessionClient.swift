import Foundation

public enum LogLevel: Int {
    case error, warn, info, debug, verbose
}

public protocol TerminalSessionClient: AnyObject {

    func onTextChanged(_ session: TerminalSession)

    func onTitleChanged(_ session: TerminalSession)

    func onSessionFinished(_ session: TerminalSession)

    func onCopyTextToClipboard(_ session: TerminalSession, text: String)

    func onPasteTextFromClipboard(_ session: TerminalSession?)

    func onBell(_ session: TerminalSession)

    func onColorsChanged(_ session: TerminalSession)

    func onTerminalCursorStateChange(_ state: Bool)

    var terminalCursorStyle: Int? { get }

    func log(_ level: LogLevel, tag: String, _ message: String)
}

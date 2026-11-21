import Foundation
import TermuxTerminal
import TermuxShell

/// Receives the `TerminalSessionClient` callbacks of all sessions. Implemented by
/// `TerminalViewController` (port of `TermuxTerminalSessionActivityClient`).
protocol SessionManagerDelegate: AnyObject {
    func sessionManager(_ manager: SessionManager, textChangedIn session: TerminalSession)
    func sessionManager(_ manager: SessionManager, titleChangedIn session: TerminalSession)
    func sessionManager(_ manager: SessionManager, sessionFinished session: TerminalSession)
    func sessionManager(_ manager: SessionManager, copyText text: String, from session: TerminalSession)
    func sessionManager(_ manager: SessionManager, pasteInto session: TerminalSession?)
    func sessionManager(_ manager: SessionManager, bellIn session: TerminalSession)
    func sessionManager(_ manager: SessionManager, colorsChangedIn session: TerminalSession)
    func sessionManager(_ manager: SessionManager, cursorStateChanged enabled: Bool)
    func sessionManagerSessionsDidChange(_ manager: SessionManager)
}

/// Owns the terminal sessions, independent of the view lifecycle. The iOS counterpart of
/// `TermuxService` (which keeps the sessions alive on Android) and
/// `TermuxTerminalSessionServiceClient`.
///
/// Every session runs a `BuiltinShellBackend` with `$HOME` = `Documents/home`.
final class SessionManager: TerminalSessionClient {

    private static let LOG_TAG = "SessionManager"

    private unowned let environment: TermuxEnvironment
    weak var delegate: SessionManagerDelegate?

    private(set) var sessions: [TerminalSession] = []
    /// The handle of the session last shown, to restore it when the view is recreated.
    var currentSessionHandle: String?

    /// Sessions that still need the message of the day printed (once their emulator exists).
    private var motdPending: Set<String> = []

    init(environment: TermuxEnvironment) {
        self.environment = environment
    }

    var currentSession: TerminalSession? {
        if let handle = currentSessionHandle, let session = sessions.first(where: { $0.handle == handle }) {
            return session
        }
        return sessions.last
    }

    func index(of session: TerminalSession) -> Int? {
        return sessions.firstIndex { $0 === session }
    }

    /// Create a new session. Port of `TermuxService.createTermuxSession()`.
    @discardableResult
    func addNewSession(name: String?) -> TerminalSession {
        let backend = BuiltinShellBackend(homeDirectory: environment.paths.homeDirectory,
                                          environment: environment.shellEnvironment())
        let session = TerminalSession(backend: backend,
                                      transcriptRows: environment.properties.terminalTranscriptRows,
                                      client: self)
        if let name = name, !name.isEmpty {
            session.sessionName = name
        }
        sessions.append(session)
        motdPending.insert(session.handle)
        delegate?.sessionManagerSessionsDidChange(self)
        return session
    }

    /// Called when the emulator of a session was created by its first `updateSize()` (which also
    /// starts the shell): prints the message of the day before the shell's first prompt, like
    /// the `login` script of Termux does.
    func emulatorCreated(for session: TerminalSession) {
        guard motdPending.remove(session.handle) != nil, let emulator = session.emulator else { return }
        var text = ""
        if let error = environment.bootstrapError {
            text += "\u{1B}[31m\(error)\u{1B}[0m\n"
        }
        if let motd = Bootstrap.motd(paths: environment.paths) {
            text += motd
        }
        guard !text.isEmpty else { return }
        let bytes = Array(Bootstrap.terminalText(text).utf8)
        emulator.append(bytes, length: bytes.count)
        delegate?.sessionManager(self, textChangedIn: session)
    }

    /// Remove a session (finishing it if still running). Returns the index it had.
    @discardableResult
    func removeSession(_ session: TerminalSession) -> Int? {
        guard let index = index(of: session) else { return nil }
        sessions.remove(at: index)
        motdPending.remove(session.handle)
        // Remove first so that the onSessionFinished callback is ignored for it.
        session.finishIfRunning()
        if currentSessionHandle == session.handle {
            currentSessionHandle = nil
        }
        delegate?.sessionManagerSessionsDidChange(self)
        return index
    }

    func renameSession(_ session: TerminalSession, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        session.sessionName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        delegate?.sessionManagerSessionsDidChange(self)
    }

    /// The text shown for a session in the drawer and toasts. Port of `toToastTitle()`.
    func displayName(of session: TerminalSession) -> String {
        let number = (index(of: session) ?? 0) + 1
        var title = "[\(number)]"
        if let name = session.sessionName, !name.isEmpty {
            title += " \(name)"
        }
        if let sessionTitle = session.title, !sessionTitle.isEmpty, sessionTitle != session.sessionName {
            title += (session.sessionName == nil ? " " : ": ") + sessionTitle
        }
        return title
    }

    // MARK: - TerminalSessionClient

    func onTextChanged(_ session: TerminalSession) {
        delegate?.sessionManager(self, textChangedIn: session)
    }

    func onTitleChanged(_ session: TerminalSession) {
        delegate?.sessionManager(self, titleChangedIn: session)
    }

    func onSessionFinished(_ session: TerminalSession) {
        // Ignore sessions that were removed (killed) already.
        guard index(of: session) != nil else { return }
        delegate?.sessionManager(self, sessionFinished: session)
    }

    func onCopyTextToClipboard(_ session: TerminalSession, text: String) {
        delegate?.sessionManager(self, copyText: text, from: session)
    }

    func onPasteTextFromClipboard(_ session: TerminalSession?) {
        delegate?.sessionManager(self, pasteInto: session)
    }

    func onBell(_ session: TerminalSession) {
        delegate?.sessionManager(self, bellIn: session)
    }

    func onColorsChanged(_ session: TerminalSession) {
        delegate?.sessionManager(self, colorsChangedIn: session)
    }

    func onTerminalCursorStateChange(_ state: Bool) {
        delegate?.sessionManager(self, cursorStateChanged: state)
    }

    var terminalCursorStyle: Int? {
        return environment.properties.terminalCursorStyle
    }

    func log(_ level: LogLevel, tag: String, _ message: String) {
        switch level {
        case .error, .warn:
            NSLog("%@: %@", tag, message)
        case .info, .debug, .verbose:
            #if DEBUG
            NSLog("%@: %@", tag, message)
            #endif
        }
    }
}

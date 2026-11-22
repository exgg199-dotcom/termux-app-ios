import Foundation
import Combine
import TermuxTerminal
import TermuxShell

protocol SessionManagerDelegate: AnyObject {
    func sessionManager(_ manager: SessionManager, textChangedIn session: TerminalSession)
    func sessionManager(_ manager: SessionManager, titleChangedIn session: TerminalSession)
    func sessionManager(_ manager: SessionManager, sessionFinished session: TerminalSession)
    func sessionManager(_ manager: SessionManager, copyText text: String, from session: TerminalSession)
    func sessionManager(_ manager: SessionManager, pasteInto session: TerminalSession?)
    func sessionManager(_ manager: SessionManager, bellIn session: TerminalSession)
    func sessionManager(_ manager: SessionManager, colorsChangedIn session: TerminalSession)
    func sessionManager(_ manager: SessionManager, cursorStateChanged enabled: Bool)
}

struct SessionListItem: Identifiable, Equatable {
    let id: String
    let index: Int
    let title: String
    let subtitle: String?
    let isCurrent: Bool
    let isRunning: Bool
    let exitStatus: Int32
}

final class SessionManager: ObservableObject, TerminalSessionClient {
    private unowned let environment: TermuxEnvironment
    weak var delegate: SessionManagerDelegate?

    @Published private(set) var sessions: [TerminalSession] = []
    @Published var currentSessionHandle: String?
    @Published private(set) var listRevision = 0

    private var messageOfTheDayPending: Set<String> = []

    init(environment: TermuxEnvironment) {
        self.environment = environment
    }

    var currentSession: TerminalSession? {
        if let handle = currentSessionHandle, let session = sessions.first(where: { $0.handle == handle }) {
            return session
        }
        return sessions.last
    }

    var listItems: [SessionListItem] {
        let current = currentSession
        return sessions.enumerated().map { index, session in
            SessionListItem(id: session.handle,
                            index: index,
                            title: displayName(of: session),
                            subtitle: session.title,
                            isCurrent: session === current,
                            isRunning: session.isRunning,
                            exitStatus: session.exitStatus)
        }
    }

    func index(of session: TerminalSession) -> Int? {
        return sessions.firstIndex { $0 === session }
    }

    func session(withHandle handle: String) -> TerminalSession? {
        return sessions.first { $0.handle == handle }
    }

    @discardableResult
    func addNewSession(name: String?) -> TerminalSession {
        let backend = BuiltinShellBackend(homeDirectory: environment.paths.homeDirectory,
                                          environment: environment.shellEnvironment())
        backend.showsWelcome = false
        let session = TerminalSession(backend: backend,
                                      transcriptRows: environment.properties.terminalTranscriptRows,
                                      client: self)
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            session.sessionName = name
        }
        sessions.append(session)
        messageOfTheDayPending.insert(session.handle)
        listChanged()
        return session
    }

    func emulatorCreated(for session: TerminalSession) {
        guard messageOfTheDayPending.remove(session.handle) != nil, let emulator = session.emulator else { return }
        var text = ""
        if let error = environment.bootstrapError {
            text += "\u{1B}[31m\(error)\u{1B}[0m\n"
        }
        if let messageOfTheDay = Bootstrap.motd(paths: environment.paths) {
            text += messageOfTheDay
        }
        guard !text.isEmpty else { return }
        let bytes = Array(Bootstrap.terminalText(text).utf8)
        emulator.append(bytes, length: bytes.count)
        delegate?.sessionManager(self, textChangedIn: session)
    }

    @discardableResult
    func removeSession(_ session: TerminalSession) -> Int? {
        guard let index = index(of: session) else { return nil }
        sessions.remove(at: index)
        messageOfTheDayPending.remove(session.handle)
        session.finishIfRunning()
        if currentSessionHandle == session.handle {
            currentSessionHandle = nil
        }
        listChanged()
        return index
    }

    func renameSession(_ session: TerminalSession, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        session.sessionName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        listChanged()
    }

    func listChanged() {
        listRevision += 1
    }

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

    func onTextChanged(_ session: TerminalSession) {
        delegate?.sessionManager(self, textChangedIn: session)
    }

    func onTitleChanged(_ session: TerminalSession) {
        listChanged()
        delegate?.sessionManager(self, titleChangedIn: session)
    }

    func onSessionFinished(_ session: TerminalSession) {
        guard index(of: session) != nil else { return }
        listChanged()
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

import Foundation

/// A source of terminal output and sink of terminal input: a process with a pseudo-terminal, an in-process shell,
/// an SSH connection, etc. (Replaces the Android JNI `forkpty` subprocess.)
public protocol TerminalBackend: AnyObject {
    /// Called with process output. May be called on any thread.
    var onOutput: (([UInt8]) -> Void)? { get set }
    /// Called once when the process/shell exits. May be called on any thread.
    var onExit: ((Int32) -> Void)? { get set }
    func start(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int)
    /// Keyboard input → process.
    func write(_ data: [UInt8])
    func resize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int)
    func terminate()
    /// -1 if not a real process.
    var pid: Int32 { get }
}

/// A terminal session, consisting of a `TerminalBackend` (process / shell) coupled to a terminal interface.
///
/// The backend is started when the size is made known by the first call to
/// `updateSize(columns:rows:cellWidthPixels:cellHeightPixels:)`. All terminal emulation and client callbacks are
/// performed on the main thread (`DispatchQueue.main`).
///
/// The backend may be terminated forcefully by using `finishIfRunning()`.
public final class TerminalSession: TerminalOutput {

    public let handle: String = UUID().uuidString

    public private(set) var emulator: TerminalEmulator?

    /// Callback which gets notified when a session finishes or changes title.
    public private(set) var client: TerminalSessionClient?

    /// Set by the application for user identification of session, not by terminal.
    public var sessionName: String?

    public let backend: TerminalBackend

    private let transcriptRows: Int?

    private let lock = NSLock()
    private var started = false
    private var exited = false
    private var shellExitStatus: Int32 = 0

    private static let LOG_TAG = "TerminalSession"

    public init(backend: TerminalBackend, transcriptRows: Int?, client: TerminalSessionClient?) {
        self.backend = backend
        self.transcriptRows = transcriptRows
        self.client = client
    }

    /// - Parameter client: The `TerminalSessionClient` implementation to allow for communication between
    ///   `TerminalSession` and its client.
    public func updateTerminalSessionClient(_ client: TerminalSessionClient?) {
        self.client = client
        emulator?.updateTerminalSessionClient(client)
    }

    /// Inform the backend of the new size and reflow or initialize the emulator.
    public func updateSize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        if let emulator = emulator {
            if isRunning {
                backend.resize(columns: columns, rows: rows, cellWidthPixels: cellWidthPixels, cellHeightPixels: cellHeightPixels)
            }
            emulator.resize(columns: columns, rows: rows, cellWidthPixels: cellWidthPixels, cellHeightPixels: cellHeightPixels)
        } else {
            initializeEmulator(columns: columns, rows: rows, cellWidthPixels: cellWidthPixels, cellHeightPixels: cellHeightPixels)
        }
    }

    /// The terminal title as set through escape sequences or nil if none set.
    public var title: String? {
        return emulator?.title
    }

    /// Set the terminal emulator's window size and start terminal emulation.
    public func initializeEmulator(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        emulator = TerminalEmulator(output: self, columns: columns, rows: rows, cellWidthPixels: cellWidthPixels,
                                    cellHeightPixels: cellHeightPixels, transcriptRows: transcriptRows, client: client)

        backend.onOutput = { [weak self] data in
            if data.isEmpty { return }
            DispatchQueue.main.async {
                guard let self = self, let emulator = self.emulator else { return }
                emulator.append(data, length: data.count)
                self.notifyScreenUpdate()
            }
        }
        backend.onExit = { [weak self] exitCode in
            DispatchQueue.main.async {
                self?.processExited(exitCode)
            }
        }

        lock.lock()
        started = true
        lock.unlock()

        backend.start(columns: columns, rows: rows, cellWidthPixels: cellWidthPixels, cellHeightPixels: cellHeightPixels)
    }

    private func processExited(_ exitCode: Int32) {
        lock.lock()
        if exited {
            lock.unlock()
            return
        }
        exited = true
        shellExitStatus = exitCode
        lock.unlock()

        var exitDescription = "\r\n[Process completed"
        if exitCode > 0 {
            // Non-zero process exit.
            exitDescription += " (code \(exitCode))"
        } else if exitCode < 0 {
            // Negated signal.
            exitDescription += " (signal \(-Int(exitCode)))"
        }
        exitDescription += " - press Enter]"

        let bytesToWrite = Array(exitDescription.utf8)
        emulator?.append(bytesToWrite, length: bytesToWrite.count)
        notifyScreenUpdate()

        client?.onSessionFinished(self)
    }

    /// Write data to the shell process.
    public func write(_ data: [UInt8]) {
        lock.lock()
        let canWrite = started && !exited
        lock.unlock()
        if canWrite && !data.isEmpty { backend.write(data) }
    }

    /// Write the Unicode code point to the terminal encoded in UTF-8.
    public func writeCodePoint(prependEscape: Bool, codePoint: Int) {
        if codePoint > 1114111 || codePoint < 0 || (codePoint >= 0xD800 && codePoint <= 0xDFFF) {
            // 1114111 (= 2**16 + 1024**2 - 1) is the highest code point, [0xD800,0xDFFF] is the surrogate range.
            Logger.logError(client, TerminalSession.LOG_TAG, "Invalid code point: \(codePoint)")
            return
        }

        var buffer = [UInt8]()
        buffer.reserveCapacity(5)
        if prependEscape { buffer.append(27) }

        if codePoint <= /* 7 bits */ 0b1111111 {
            buffer.append(UInt8(codePoint))
        } else if codePoint <= /* 11 bits */ 0b11111111111 {
            /* 110xxxxx leading byte with leading 5 bits */
            buffer.append(UInt8(0b11000000 | (codePoint >> 6)))
            /* 10xxxxxx continuation byte with following 6 bits */
            buffer.append(UInt8(0b10000000 | (codePoint & 0b111111)))
        } else if codePoint <= /* 16 bits */ 0b1111111111111111 {
            /* 1110xxxx leading byte with leading 4 bits */
            buffer.append(UInt8(0b11100000 | (codePoint >> 12)))
            /* 10xxxxxx continuation byte with following 6 bits */
            buffer.append(UInt8(0b10000000 | ((codePoint >> 6) & 0b111111)))
            /* 10xxxxxx continuation byte with following 6 bits */
            buffer.append(UInt8(0b10000000 | (codePoint & 0b111111)))
        } else { /* We have checked codePoint <= 1114111 above, so we have max 21 bits = 0b111111111111111111111 */
            /* 11110xxx leading byte with leading 3 bits */
            buffer.append(UInt8(0b11110000 | (codePoint >> 18)))
            /* 10xxxxxx continuation byte with following 6 bits */
            buffer.append(UInt8(0b10000000 | ((codePoint >> 12) & 0b111111)))
            /* 10xxxxxx continuation byte with following 6 bits */
            buffer.append(UInt8(0b10000000 | ((codePoint >> 6) & 0b111111)))
            /* 10xxxxxx continuation byte with following 6 bits */
            buffer.append(UInt8(0b10000000 | (codePoint & 0b111111)))
        }
        write(buffer)
    }

    /// Notify the client that the screen has changed.
    func notifyScreenUpdate() {
        client?.onTextChanged(self)
    }

    /// Reset state for terminal emulator state.
    public func reset() {
        emulator?.reset()
        notifyScreenUpdate()
    }

    /// Finish this terminal session by terminating the backend (SIGKILL on Android).
    public func finishIfRunning() {
        if isRunning {
            backend.terminate()
        }
    }

    public func titleChanged(oldTitle: String?, newTitle: String?) {
        client?.onTitleChanged(self)
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !exited
    }

    /// Only valid if not `isRunning`.
    public var exitStatus: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return shellExitStatus
    }

    public func onCopyTextToClipboard(_ text: String) {
        client?.onCopyTextToClipboard(self, text: text)
    }

    public func onPasteTextFromClipboard() {
        client?.onPasteTextFromClipboard(self)
    }

    public func onBell() {
        client?.onBell(self)
    }

    public func onColorsChanged() {
        client?.onColorsChanged(self)
    }

    /// The pid of the backend process: 0 if not started, -1 if finished running (or if the backend is not a real
    /// process).
    public var pid: Int32 {
        lock.lock()
        let started = self.started
        let exited = self.exited
        lock.unlock()
        if exited { return -1 }
        if !started { return 0 }
        return backend.pid
    }
}

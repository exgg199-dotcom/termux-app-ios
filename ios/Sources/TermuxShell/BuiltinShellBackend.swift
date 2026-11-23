import Foundation
import TermuxTerminal

public final class BuiltinShellBackend: TerminalBackend {
    public var onOutput: (([UInt8]) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onOutput }
        set { callbackLock.lock(); _onOutput = newValue; callbackLock.unlock() }
    }
    public var onExit: ((Int32) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onExit }
        set { callbackLock.lock(); _onExit = newValue; callbackLock.unlock() }
    }
    public var pid: Int32 { -1 }

    public let homeDirectory: URL
    public let interpreter: ShellInterpreter
    public var showsWelcome = true
    public var continuationPrompt = "> "

    private let lock = NSRecursiveLock()
    private let callbackLock = NSLock()
    private var _onOutput: (([UInt8]) -> Void)?
    private var _onExit: ((Int32) -> Void)?
    private let editor = LineEditor()
    private let execQueue = DispatchQueue(label: "com.termux.shell.exec", qos: .userInitiated)
    private var writer: TerminalWriter!
    private var terminalInput: TerminalInputStream!
    private var streams: StandardStreams!
    private var started = false
    private var exited = false
    private var running = false
    private var continuation = ""
    private var currentToken = CancellationToken()

    public init(homeDirectory: URL, environment: [String: String] = [:], programRunner: ProgramRunner? = nil) {
        self.homeDirectory = homeDirectory
        let home = homeDirectory.standardizedFileURL.path
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let history = ShellHistory(file: home + "/.termux_history")
        interpreter = ShellInterpreter(homeDirectory: home, environment: environment, history: history)
        interpreter.programRunner = programRunner
        writer = TerminalWriter { [weak self] bytes in self?.onOutput?(bytes) }
        terminalInput = TerminalInputStream(echo: { [weak self] bytes in self?.writer.write(bytes, immediate: true) })
        let out = TerminalOutputStream(writer: writer)
        streams = StandardStreams(stdin: terminalInput, stdout: out, stderr: out)
        editor.enablesBracketedPaste = true
        editor.completer = { [weak self] line in
            self?.interpreter.complete(line) ?? ShellInterpreter.Completion(wordStart: 0, candidates: [], displays: [])
        }
    }

    public var isRunningCommand: Bool { lock.lock(); defer { lock.unlock() }; return running }

    public func start(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        applySize(columns: columns, rows: rows)
        running = true
        let token = CancellationToken()
        currentToken = token
        terminalInput.reset(token)
        execQueue.async { [self] in
            let fileManager = FileManager.default
            let home = interpreter.homeDirectory
            if showsWelcome && !fileManager.fileExists(atPath: home + "/.hushlogin") {
                streams.stdout.write(BuiltinShellBackend.welcome)
            }
            for startupFile in [".profile", ".shrc"] {
                let path = home + "/" + startupFile
                if fileManager.fileExists(atPath: path) && interpreter.exitRequested == nil {
                    _ = interpreter.source(file: path, arguments: [], streams: streams, cancellation: token)
                }
            }
            commandFinished()
        }
    }

    public func write(_ data: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard started, !exited, !data.isEmpty else { return }
        if running {
            var chunk: [UInt8] = []
            for b in data {
                if b == 0x03 || b == 0x1C {
                    if !chunk.isEmpty { terminalInput.receive(chunk); chunk = [] }
                    interruptRunningCommand()
                } else {
                    chunk.append(b)
                }
            }
            if !chunk.isEmpty { terminalInput.receive(chunk) }
        } else {
            processEditorInput(data[...])
        }
    }

    public func resize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        lock.lock()
        applySize(columns: columns, rows: rows)
        lock.unlock()
    }

    public func terminate() {
        lock.lock()
        let wasExited = exited
        if !exited { currentToken.cancel() }
        lock.unlock()
        if !wasExited { finish(-9) }
    }

    static let welcome = """
    Welcome to Termux for iOS!

    iOS does not allow apps to run native programs, so this is a
    built-in shell with common commands implemented inside the app.
    Packages are WebAssembly programs; Android Termux packages
    cannot run on iOS.

    Working with files:  ls, cd, cat, cp, mv, rm, mkdir, find, grep
    Run 'help' to list all commands.

    Working with packages:
     - Search packages:   pkg search <query>
     - Install a package: pkg install <package>
     - Upgrade packages:  pkg upgrade

    """

    private func applySize(columns: Int, rows: Int) {
        interpreter.terminalColumns = columns
        interpreter.terminalRows = rows
        editor.resize(columns: columns)
        interpreter.setVariable("COLUMNS", String(columns))
        interpreter.setVariable("LINES", String(rows))
    }

    private func interruptRunningCommand() {
        currentToken.cancel()
        terminalInput.discardInput()
        writer.write(Array("^C\r\n".utf8), immediate: true)
    }

    private func processEditorInput(_ bytes: ArraySlice<UInt8>) {
        var rest = bytes
        while !rest.isEmpty && !running && !exited {
            let result = editor.feed(Array(rest))
            writer.write(result.output, immediate: true)
            rest = rest.dropFirst(result.consumed)
            switch result.event {
            case nil:
                break
            case .submit(let line)?:
                handleLine(line)
            case .interrupt?:
                continuation = ""
                interpreter.lastStatus = 130
                showPrompt()
            case .endOfFile?:
                if !continuation.isEmpty {
                    writer.write(Array("\r\n\(interpreter.shellName): syntax error: unexpected end of file\r\n".utf8), immediate: true)
                    continuation = ""
                    showPrompt()
                } else {
                    writer.write(Array("\r\n".utf8), immediate: true)
                    finish(interpreter.lastStatus)
                    return
                }
            }
        }
        if running && !rest.isEmpty { terminalInput.receive(Array(rest)) }
    }

    private func showPrompt() {
        editor.history = interpreter.history.all
        let prompt = continuation.isEmpty ? interpreter.prompt() : continuationPrompt
        writer.write(editor.begin(prompt: prompt), immediate: true)
    }

    private func handleLine(_ line: String) {
        let source = continuation.isEmpty ? line : continuation + "\n" + line
        do {
            _ = try interpreter.parse(source)
        } catch ShellSyntaxError.incomplete {
            continuation = source
            showPrompt()
            return
        } catch {
        }
        continuation = ""
        interpreter.history.add(source)
        if source.trimmingCharacters(in: .whitespaces).isEmpty {
            showPrompt()
            return
        }
        running = true
        let token = CancellationToken()
        currentToken = token
        terminalInput.reset(token)
        execQueue.async { [self] in
            _ = interpreter.run(source, streams: streams, cancellation: token)
            commandFinished()
        }
    }

    private func commandFinished() {
        streams.stdout.flush()
        lock.lock()
        defer { lock.unlock() }
        guard !exited else { return }
        running = false
        if let code = interpreter.exitRequested {
            finish(code)
            return
        }
        let leftover = terminalInput.takeLeftover()
        showPrompt()
        if !leftover.isEmpty { processEditorInput(leftover[...]) }
    }

    private func finish(_ code: Int32) {
        lock.lock()
        guard !exited else { lock.unlock(); return }
        exited = true
        lock.unlock()
        let callback = onExit
        writer.flush()
        callback?(code)
    }
}

final class TerminalWriter {
    private let lock = NSLock()
    private let emitLock = NSRecursiveLock()
    private var buffer: [UInt8] = []
    private var flushScheduled = false
    private let sink: ([UInt8]) -> Void

    init(sink: @escaping ([UInt8]) -> Void) { self.sink = sink }

    func write(_ bytes: [UInt8], immediate: Bool = false) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        buffer.append(contentsOf: bytes)
        let big = buffer.count >= 16384
        var schedule = false
        if !immediate && !big && !flushScheduled { flushScheduled = true; schedule = true }
        lock.unlock()
        if immediate || big {
            flush()
        } else if schedule {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in self?.flush() }
        }
    }

    func flush() {
        emitLock.lock()
        defer { emitLock.unlock() }
        lock.lock()
        let data = buffer
        buffer = []
        flushScheduled = false
        lock.unlock()
        if !data.isEmpty { sink(data) }
    }
}

final class TerminalOutputStream: ShellOutputStream {
    private let writer: TerminalWriter
    init(writer: TerminalWriter) { self.writer = writer }
    func write(_ bytes: [UInt8]) {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 16)
        for b in bytes {
            if b == 0x0A { out.append(0x0D) }
            out.append(b)
        }
        writer.write(out)
    }
    var isClosed: Bool { false }
    var isTerminal: Bool { true }
    func flush() { writer.flush() }
}

final class TerminalInputStream: ShellInputStream {
    private let condition = NSCondition()
    private var raw: [UInt8] = []
    private var lineBuffer: [UInt8] = []
    private var ready: [UInt8] = []
    private var eofPending = false
    private var readerWaiting = false
    private var lastWasCarriageReturn = false
    private var escapeState = 0
    private var token = CancellationToken()
    private let echo: ([UInt8]) -> Void

    init(echo: @escaping ([UInt8]) -> Void) { self.echo = echo }

    var isTerminal: Bool { true }

    func reset(_ token: CancellationToken) {
        condition.lock()
        self.token = token
        ready = []; lineBuffer = []; eofPending = false; escapeState = 0
        condition.unlock()
    }

    func receive(_ bytes: [UInt8]) {
        condition.lock()
        raw.append(contentsOf: bytes)
        if readerWaiting { processRaw() }
        condition.broadcast()
        condition.unlock()
    }

    func discardInput() {
        condition.lock()
        raw = []; lineBuffer = []; ready = []; eofPending = false
        condition.broadcast()
        condition.unlock()
    }

    func takeLeftover() -> [UInt8] {
        condition.lock()
        defer { condition.unlock() }
        let left = ready + lineBuffer + raw
        ready = []; lineBuffer = []; raw = []; eofPending = false
        return left
    }

    func read(maxLength: Int) -> [UInt8]? {
        condition.lock()
        defer { readerWaiting = false; condition.unlock() }
        while true {
            if !ready.isEmpty {
                let n = min(maxLength, ready.count)
                let chunk = Array(ready[0..<n])
                ready.removeFirst(n)
                return chunk
            }
            if eofPending { eofPending = false; return nil }
            if token.isCancelled { return nil }
            readerWaiting = true
            if !raw.isEmpty { processRaw(); continue }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
    }

    private func processRaw() {
        var echoOut: [UInt8] = []
        var i = 0
        while i < raw.count {
            let b = raw[i]
            i += 1
            let wasCarriageReturn = lastWasCarriageReturn
            lastWasCarriageReturn = false
            if escapeState == 1 { escapeState = b == UInt8(ascii: "[") || b == UInt8(ascii: "O") ? 2 : 0; continue }
            if escapeState == 2 { if (0x40...0x7E).contains(b) { escapeState = 0 }; continue }
            switch b {
            case 0x1B: escapeState = 1
            case 0x0D, 0x0A:
                if b == 0x0A && wasCarriageReturn { continue }
                lastWasCarriageReturn = b == 0x0D
                echoOut += [0x0D, 0x0A]
                ready += lineBuffer + [0x0A]
                lineBuffer = []
            case 0x04:
                if lineBuffer.isEmpty { eofPending = true } else { ready += lineBuffer; lineBuffer = [] }
                raw.removeFirst(i)
                if !echoOut.isEmpty { echo(echoOut) }
                return
            case 0x7F, 0x08:
                guard !lineBuffer.isEmpty else { continue }
                var removed: [UInt8] = []
                while let last = lineBuffer.popLast() {
                    removed.insert(last, at: 0)
                    if last & 0xC0 != 0x80 { break }
                }
                let w = DisplayWidth.of(String(decoding: removed, as: UTF8.self))
                for _ in 0..<max(1, w) { echoOut += [0x08, 0x20, 0x08] }
            case 0x15:
                let w = DisplayWidth.of(String(decoding: lineBuffer, as: UTF8.self))
                for _ in 0..<w { echoOut += [0x08, 0x20, 0x08] }
                lineBuffer = []
            case 0x09:
                lineBuffer.append(b); echoOut.append(b)
            default:
                if b < 0x20 { continue }
                lineBuffer.append(b); echoOut.append(b)
            }
        }
        raw = []
        if !echoOut.isEmpty { echo(echoOut) }
    }
}

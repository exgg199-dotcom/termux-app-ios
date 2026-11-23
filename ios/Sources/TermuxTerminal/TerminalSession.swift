import Foundation

public protocol TerminalBackend: AnyObject {
    var onOutput: (([UInt8]) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    func start(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int)
    func write(_ data: [UInt8])
    func resize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int)
    func terminate()
    var pid: Int32 { get }
}

public final class TerminalSession: TerminalOutput {

    public let handle: String = UUID().uuidString

    public private(set) var emulator: TerminalEmulator?

    public private(set) var client: TerminalSessionClient?

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

    public func updateTerminalSessionClient(_ client: TerminalSessionClient?) {
        self.client = client
        emulator?.updateTerminalSessionClient(client)
    }

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

    public var title: String? {
        return emulator?.title
    }

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
            exitDescription += " (code \(exitCode))"
        } else if exitCode < 0 {
            exitDescription += " (signal \(-Int(exitCode)))"
        }
        exitDescription += " - press Enter]"

        let bytesToWrite = Array(exitDescription.utf8)
        emulator?.append(bytesToWrite, length: bytesToWrite.count)
        notifyScreenUpdate()

        client?.onSessionFinished(self)
    }

    public func write(_ data: [UInt8]) {
        lock.lock()
        let canWrite = started && !exited
        lock.unlock()
        if canWrite && !data.isEmpty { backend.write(data) }
    }

    public func writeCodePoint(prependEscape: Bool, codePoint: Int) {
        if codePoint > 1114111 || codePoint < 0 || (codePoint >= 0xD800 && codePoint <= 0xDFFF) {
            Logger.logError(client, TerminalSession.LOG_TAG, "Invalid code point: \(codePoint)")
            return
        }

        var buffer = [UInt8]()
        buffer.reserveCapacity(5)
        if prependEscape { buffer.append(27) }

        if codePoint <=  0b1111111 {
            buffer.append(UInt8(codePoint))
        } else if codePoint <=  0b11111111111 {
            buffer.append(UInt8(0b11000000 | (codePoint >> 6)))
            buffer.append(UInt8(0b10000000 | (codePoint & 0b111111)))
        } else if codePoint <=  0b1111111111111111 {
            buffer.append(UInt8(0b11100000 | (codePoint >> 12)))
            buffer.append(UInt8(0b10000000 | ((codePoint >> 6) & 0b111111)))
            buffer.append(UInt8(0b10000000 | (codePoint & 0b111111)))
        } else {
            buffer.append(UInt8(0b11110000 | (codePoint >> 18)))
            buffer.append(UInt8(0b10000000 | ((codePoint >> 12) & 0b111111)))
            buffer.append(UInt8(0b10000000 | ((codePoint >> 6) & 0b111111)))
            buffer.append(UInt8(0b10000000 | (codePoint & 0b111111)))
        }
        write(buffer)
    }

    func notifyScreenUpdate() {
        client?.onTextChanged(self)
    }

    public func reset() {
        emulator?.reset()
        notifyScreenUpdate()
    }

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

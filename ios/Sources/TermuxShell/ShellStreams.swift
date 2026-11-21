import Foundation

// MARK: - Cancellation

/// Cooperative cancellation flag shared by all commands of one top-level execution.
/// Ctrl-C sets it; long-running commands poll `isCancelled` or use `sleep(_:)`.
public final class CancellationToken {
    private let condition = NSCondition()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    /// Sleeps for `seconds` or until cancelled. Returns false if cancelled.
    @discardableResult
    public func sleep(_ seconds: Double) -> Bool {
        let deadline = Date(timeIntervalSinceNow: max(0, seconds))
        condition.lock(); defer { condition.unlock() }
        while !cancelled {
            if !condition.wait(until: deadline) { break }
        }
        return !cancelled
    }
}

// MARK: - Output streams

public protocol ShellOutputStream: AnyObject {
    func write(_ bytes: [UInt8])
    /// True once the consumer went away (e.g. the reading end of a pipe was closed).
    var isClosed: Bool { get }
    /// True if this stream is connected to the terminal.
    var isTerminal: Bool { get }
    func flush()
}

public extension ShellOutputStream {
    func write(_ string: String) { write(Array(string.utf8)) }
    func writeLine(_ string: String = "") { write(Array((string + "\n").utf8)) }
    func flush() {}
}

/// Collects all output in memory (used for tests, command substitution, etc).
public final class BufferOutputStream: ShellOutputStream {
    private let lock = NSLock()
    private var storage: [UInt8] = []
    public var isTerminal: Bool
    public init(isTerminal: Bool = false) { self.isTerminal = isTerminal }
    public func write(_ bytes: [UInt8]) { lock.lock(); storage.append(contentsOf: bytes); lock.unlock() }
    public var isClosed: Bool { false }
    public var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return storage }
    public var string: String { String(decoding: bytes, as: UTF8.self) }
    public func clear() { lock.lock(); storage.removeAll(); lock.unlock() }
}

/// Discards everything.
public final class NullOutputStream: ShellOutputStream {
    public init() {}
    public func write(_ bytes: [UInt8]) {}
    public var isClosed: Bool { false }
    public var isTerminal: Bool { false }
}

/// Forwards to a closure.
public final class ClosureOutputStream: ShellOutputStream {
    private let sink: ([UInt8]) -> Void
    public let isTerminal: Bool
    public init(isTerminal: Bool = false, _ sink: @escaping ([UInt8]) -> Void) { self.sink = sink; self.isTerminal = isTerminal }
    public func write(_ bytes: [UInt8]) { sink(bytes) }
    public var isClosed: Bool { false }
}

/// Buffered writer to a file.
public final class FileOutputStream: ShellOutputStream {
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private let lock = NSLock()
    private var closed = false

    /// Opens (creating if necessary) the file. Returns nil on failure.
    public init?(path: String, append: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue { return nil }
        } else if !fm.createFile(atPath: path, contents: nil) {
            return nil
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        handle = h
        if append { handle.seekToEndOfFile() } else { handle.truncateFile(atOffset: 0) }
    }

    public func write(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        buffer.append(contentsOf: bytes)
        if buffer.count >= 64 * 1024 { flushLocked() }
    }
    private func flushLocked() {
        if !buffer.isEmpty { handle.write(Data(buffer)); buffer.removeAll(keepingCapacity: true) }
    }
    public func flush() { lock.lock(); flushLocked(); lock.unlock() }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        flushLocked(); closed = true
        handle.closeFile()
    }
    public var isClosed: Bool { false }
    public var isTerminal: Bool { false }
    deinit { close() }
}

// MARK: - Input streams

public protocol ShellInputStream: AnyObject {
    /// Blocks until data is available. Returns nil at end of input (or when cancelled).
    func read(maxLength: Int) -> [UInt8]?
    var isTerminal: Bool { get }
    /// Signals that no more data will be read (pipe writers then see `isClosed`).
    func close()
}

public extension ShellInputStream {
    func close() {}
    /// Reads until end of input.
    func readAll() -> [UInt8] {
        var out: [UInt8] = []
        while let chunk = read(maxLength: 65536) { out.append(contentsOf: chunk) }
        return out
    }
}

public final class EmptyInputStream: ShellInputStream {
    public init() {}
    public func read(maxLength: Int) -> [UInt8]? { nil }
    public var isTerminal: Bool { false }
}

public final class DataInputStream: ShellInputStream {
    private var data: [UInt8]
    private var offset = 0
    private let lock = NSLock()
    public init(_ bytes: [UInt8]) { data = bytes }
    public convenience init(_ string: String) { self.init(Array(string.utf8)) }
    public func read(maxLength: Int) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        guard offset < data.count else { return nil }
        let end = min(data.count, offset + maxLength)
        let chunk = Array(data[offset..<end]); offset = end
        return chunk
    }
    public var isTerminal: Bool { false }
}

public final class FileInputStream: ShellInputStream {
    private let handle: FileHandle
    public init?(path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let h = FileHandle(forReadingAtPath: path) else { return nil }
        handle = h
    }
    public func read(maxLength: Int) -> [UInt8]? {
        let d = handle.readData(ofLength: maxLength)
        return d.isEmpty ? nil : [UInt8](d)
    }
    public var isTerminal: Bool { false }
    public func close() { handle.closeFile() }
}

// MARK: - Pipe

/// In-memory bounded pipe connecting two concurrently running commands.
public final class PipeChannel {
    private let condition = NSCondition()
    private var buffer: [UInt8] = []
    private var readerClosed = false
    private var writerClosed = false
    private let capacity: Int
    private let cancellation: CancellationToken?

    public init(capacity: Int = 64 * 1024, cancellation: CancellationToken? = nil) {
        self.capacity = capacity
        self.cancellation = cancellation
    }

    public lazy var reader: Reader = Reader(self)
    public lazy var writer: Writer = Writer(self)

    fileprivate func write(_ bytes: [UInt8]) {
        var offset = 0
        condition.lock(); defer { condition.unlock() }
        while offset < bytes.count {
            if readerClosed || writerClosed { return }
            if cancellation?.isCancelled == true { return }
            let space = capacity - buffer.count
            if space <= 0 {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
                continue
            }
            let n = min(space, bytes.count - offset)
            buffer.append(contentsOf: bytes[offset..<(offset + n)])
            offset += n
            condition.broadcast()
        }
    }

    fileprivate func read(maxLength: Int) -> [UInt8]? {
        condition.lock(); defer { condition.unlock() }
        while buffer.isEmpty {
            if writerClosed || readerClosed { return nil }
            if cancellation?.isCancelled == true { return nil }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        let n = min(maxLength, buffer.count)
        let chunk = Array(buffer[0..<n])
        buffer.removeFirst(n)
        condition.broadcast()
        return chunk
    }

    fileprivate func closeWriter() { condition.lock(); writerClosed = true; condition.broadcast(); condition.unlock() }
    fileprivate func closeReader() { condition.lock(); readerClosed = true; buffer.removeAll(); condition.broadcast(); condition.unlock() }
    fileprivate var isReaderClosed: Bool { condition.lock(); defer { condition.unlock() }; return readerClosed }

    public final class Reader: ShellInputStream {
        unowned let pipe: PipeChannel
        init(_ pipe: PipeChannel) { self.pipe = pipe }
        public func read(maxLength: Int) -> [UInt8]? { pipe.read(maxLength: maxLength) }
        public var isTerminal: Bool { false }
        public func close() { pipe.closeReader() }
    }

    public final class Writer: ShellOutputStream {
        unowned let pipe: PipeChannel
        init(_ pipe: PipeChannel) { self.pipe = pipe }
        public func write(_ bytes: [UInt8]) { pipe.write(bytes) }
        public var isClosed: Bool { pipe.isReaderClosed }
        public var isTerminal: Bool { false }
        public func close() { pipe.closeWriter() }
    }
}

// MARK: - Line reader

/// Splits an input stream into lines (without the trailing newline).
public final class LineReader {
    private let input: ShellInputStream
    private var pending: [UInt8] = []
    private var eof = false

    public init(_ input: ShellInputStream) { self.input = input }

    /// Returns the next line as raw bytes (without "\n"), or nil at end of input.
    public func nextLineBytes() -> [UInt8]? {
        while true {
            if let idx = pending.firstIndex(of: 0x0A) {
                let line = Array(pending[0..<idx])
                pending.removeFirst(idx + 1)
                return line
            }
            if eof {
                if pending.isEmpty { return nil }
                let line = pending; pending = []
                return line
            }
            if let chunk = input.read(maxLength: 65536) { pending.append(contentsOf: chunk) } else { eof = true }
        }
    }

    public func nextLine() -> String? {
        guard var bytes = nextLineBytes() else { return nil }
        if bytes.last == 0x0D { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads all remaining lines.
    public func allLines() -> [String] {
        var lines: [String] = []
        while let l = nextLine() { lines.append(l) }
        return lines
    }
}
